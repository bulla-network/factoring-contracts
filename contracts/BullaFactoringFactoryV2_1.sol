// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IInvoiceProviderAdapter.sol";
import {IBullaFrendLendV2} from "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";

/// @title Bulla Factoring Pool Interface (for verification)
interface IBullaFactoringPool {
    function bullaDao() external view returns (address);
    function protocolFeeBps() external view returns (uint16);
    function invoiceProviderAdapter() external view returns (IInvoiceProviderAdapterV2);
    function bullaFrendLend() external view returns (IBullaFrendLendV2);
    function assetAddress() external view returns (IERC20);
}

/// @title Bulla Factoring Factory V2.1
/// @author Bulla Network
/// @notice Factory contract for deploying new BullaFactoringV2_1 pools using CREATE2
/// @dev Enables dynamic subgraph indexing of new pools through emitted events
/// @dev Caller provides creation bytecode; factory verifies protocol parameters after deployment
contract BullaFactoringFactoryV2_1 is Ownable {
    /// @notice Address of the invoice provider adapter used for all pools
    IInvoiceProviderAdapterV2 public invoiceProviderAdapter;
    
    /// @notice Address of the BullaFrendLend contract
    IBullaFrendLendV2 public bullaFrendLend;
    
    /// @notice Protocol fee in basis points applied to all new pools
    uint16 public protocolFeeBps;

    /// @notice Counter for generating unique salts
    uint256 public poolNonce;

    /// @notice Mapping of allowed asset tokens for pool creation
    mapping(address => bool) public allowedAssets;

    /// @notice Fee required to create a new pool (in native ETH), used as anti-spam protection
    uint256 public poolCreationFee;

    /// @notice Emitted when a new pool is created
    event PoolCreated(
        address indexed pool,
        address indexed owner,
        address indexed asset,
        string poolName,
        string tokenName,
        string tokenSymbol,
        address depositPermissions,
        address redeemPermissions,
        address factoringPermissions
    );

    /// @notice Emitted when the invoice provider adapter is updated
    event InvoiceProviderAdapterChanged(address indexed oldAdapter, address indexed newAdapter);
    
    /// @notice Emitted when the BullaFrendLend address is updated
    event BullaFrendLendChanged(address indexed oldAddress, address indexed newAddress);
    
    /// @notice Emitted when the protocol fee is updated
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);

    /// @notice Emitted when an asset is added to or removed from the whitelist
    event AssetWhitelistChanged(address indexed asset, bool allowed);

    /// @notice Emitted when the pool creation fee is updated
    event PoolCreationFeeChanged(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when collected fees are withdrawn
    event FeesWithdrawn(address indexed to, uint256 amount);

    error InvalidAddress();
    error InvalidPercentage();
    error AssetNotAllowed(address asset);
    error IncorrectFee(uint256 required, uint256 provided);
    error TransferFailed();
    error DeploymentFailed();
    error InvalidBullaDao(address expected, address actual);
    error InvalidProtocolFee(uint16 expected, uint16 actual);
    error InvalidInvoiceAdapter(address expected, address actual);
    error InvalidBullaFrendLend(address expected, address actual);

    /// @notice Creates a new BullaFactoringFactoryV2_1
    /// @param _invoiceProviderAdapter Address of the invoice provider adapter
    /// @param _bullaFrendLend Address of the BullaFrendLend contract
    /// @param _bullaDao Address of the factory owner (typically BullaDao), also becomes bullaDao for all created pools
    /// @param _protocolFeeBps Protocol fee in basis points
    constructor(
        IInvoiceProviderAdapterV2 _invoiceProviderAdapter,
        IBullaFrendLendV2 _bullaFrendLend,
        address _bullaDao,
        uint16 _protocolFeeBps
    ) Ownable(_bullaDao) {
        if (address(_invoiceProviderAdapter) == address(0)) revert InvalidAddress();
        if (_bullaDao == address(0)) revert InvalidAddress();
        if (_protocolFeeBps > 10000) revert InvalidPercentage();

        invoiceProviderAdapter = _invoiceProviderAdapter;
        bullaFrendLend = _bullaFrendLend;
        protocolFeeBps = _protocolFeeBps;
    }

    /// @notice Creates a new BullaFactoringV2_1 pool using CREATE2
    /// @dev Caller must provide creation bytecode with correct protocol parameters
    /// @dev Factory verifies bullaDao, protocolFee, invoiceAdapter, and bullaFrendLend after deployment
    /// @param creationBytecode The full creation bytecode (contract bytecode + abi-encoded constructor args)
    /// @param asset The underlying asset token address (for validation and events)
    /// @param poolName Display name of the pool (for events)
    /// @param tokenName ERC20 token name (for events)
    /// @param tokenSymbol ERC20 token symbol (for events)
    /// @param _depositPermissions Address of the deposit permissions contract
    /// @param _redeemPermissions Address of the redeem permissions contract
    /// @param _factoringPermissions Address of the factoring permissions contract
    /// @return pool Address of the newly created pool
    function createPool(
        bytes memory creationBytecode,
        address asset,
        string memory poolName,
        string memory tokenName,
        string memory tokenSymbol,
        address _depositPermissions,
        address _redeemPermissions,
        address _factoringPermissions
    ) external payable returns (address pool) {
        // Validations
        if (msg.value != poolCreationFee) revert IncorrectFee(poolCreationFee, msg.value);
        if (!allowedAssets[asset]) revert AssetNotAllowed(asset);
        if (_depositPermissions == address(0)) revert InvalidAddress();
        if (_redeemPermissions == address(0)) revert InvalidAddress();
        if (_factoringPermissions == address(0)) revert InvalidAddress();

        // Generate unique salt using nonce
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, poolNonce++));

        // Deploy using CREATE2
        assembly {
            pool := create2(0, add(creationBytecode, 0x20), mload(creationBytecode), salt)
        }

        if (pool == address(0)) revert DeploymentFailed();

        // Verify protocol-controlled parameters
        IBullaFactoringPool deployedPool = IBullaFactoringPool(pool);
        
        address expectedBullaDao = owner();
        address actualBullaDao = deployedPool.bullaDao();
        if (actualBullaDao != expectedBullaDao) {
            revert InvalidBullaDao(expectedBullaDao, actualBullaDao);
        }

        uint16 actualProtocolFee = deployedPool.protocolFeeBps();
        if (actualProtocolFee != protocolFeeBps) {
            revert InvalidProtocolFee(protocolFeeBps, actualProtocolFee);
        }

        address actualAdapter = address(deployedPool.invoiceProviderAdapter());
        if (actualAdapter != address(invoiceProviderAdapter)) {
            revert InvalidInvoiceAdapter(address(invoiceProviderAdapter), actualAdapter);
        }

        address actualFrendLend = address(deployedPool.bullaFrendLend());
        if (actualFrendLend != address(bullaFrendLend)) {
            revert InvalidBullaFrendLend(address(bullaFrendLend), actualFrendLend);
        }

        // Verify asset is allowed (check actual deployed asset, not just the parameter)
        address actualAsset = address(deployedPool.assetAddress());
        if (!allowedAssets[actualAsset]) {
            revert AssetNotAllowed(actualAsset);
        }

        // Transfer ownership to caller
        Ownable(pool).transferOwnership(msg.sender);

        emit PoolCreated(
            pool,
            msg.sender,
            asset,
            poolName,
            tokenName,
            tokenSymbol,
            _depositPermissions,
            _redeemPermissions,
            _factoringPermissions
        );

        return pool;
    }

    /// @notice Updates the invoice provider adapter
    /// @param _newAdapter The new adapter address
    function setInvoiceProviderAdapter(IInvoiceProviderAdapterV2 _newAdapter) external onlyOwner {
        if (address(_newAdapter) == address(0)) revert InvalidAddress();
        address oldAdapter = address(invoiceProviderAdapter);
        invoiceProviderAdapter = _newAdapter;
        emit InvoiceProviderAdapterChanged(oldAdapter, address(_newAdapter));
    }

    /// @notice Updates the BullaFrendLend address
    /// @param _newBullaFrendLend The new address
    function setBullaFrendLend(IBullaFrendLendV2 _newBullaFrendLend) external onlyOwner {
        if (address(_newBullaFrendLend) == address(0)) revert InvalidAddress();
        address oldAddress = address(bullaFrendLend);
        bullaFrendLend = _newBullaFrendLend;
        emit BullaFrendLendChanged(oldAddress, address(_newBullaFrendLend));
    }

    /// @notice Updates the protocol fee in basis points
    /// @param _newProtocolFeeBps The new protocol fee in basis points
    function setProtocolFeeBps(uint16 _newProtocolFeeBps) external onlyOwner {
        if (_newProtocolFeeBps > 10000) revert InvalidPercentage();
        uint16 oldProtocolFeeBps = protocolFeeBps;
        protocolFeeBps = _newProtocolFeeBps;
        emit ProtocolFeeBpsChanged(oldProtocolFeeBps, _newProtocolFeeBps);
    }

    /// @notice Adds an asset to the whitelist
    /// @param asset The asset token address to allow
    function allowAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert InvalidAddress();
        allowedAssets[asset] = true;
        emit AssetWhitelistChanged(asset, true);
    }

    /// @notice Removes an asset from the whitelist
    /// @param asset The asset token address to disallow
    function disallowAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert InvalidAddress();
        allowedAssets[asset] = false;
        emit AssetWhitelistChanged(asset, false);
    }

    /// @notice Checks if an asset is allowed for pool creation
    /// @param asset The asset token address to check
    /// @return Whether the asset is allowed
    function isAssetAllowed(address asset) external view returns (bool) {
        return allowedAssets[asset];
    }

    /// @notice Updates the pool creation fee
    /// @param _newFee The new fee amount in wei
    function setPoolCreationFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = poolCreationFee;
        poolCreationFee = _newFee;
        emit PoolCreationFeeChanged(oldFee, _newFee);
    }

    /// @notice Withdraws collected pool creation fees to the owner
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert TransferFailed();
        
        (bool success, ) = owner().call{value: balance}("");
        if (!success) revert TransferFailed();
        
        emit FeesWithdrawn(owner(), balance);
    }

    /// @notice Returns the contract's ETH balance (collected fees)
    function collectedFees() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Computes the CREATE2 address for given parameters
    /// @param creationBytecode The full creation bytecode
    /// @param creator The address that will call createPool
    /// @param nonce The poolNonce value at time of creation
    /// @return The predicted deployment address
    function computeAddress(
        bytes memory creationBytecode,
        address creator,
        uint256 nonce
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(creator, nonce));
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(creationBytecode)
        )))));
    }
}
