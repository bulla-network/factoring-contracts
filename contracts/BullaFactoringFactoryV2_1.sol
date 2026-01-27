// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IInvoiceProviderAdapter.sol";
import "./interfaces/IZodiacRoles.sol";
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
/// @dev Uses Zodiac Roles Modifier for callback whitelisting on BullaClaimV2 and BullaFrendLend
contract BullaFactoringFactoryV2_1 is Ownable {
    /// @notice Address of the invoice provider adapter used for all pools
    IInvoiceProviderAdapterV2 public invoiceProviderAdapter;
    
    /// @notice Address of the BullaFrendLend contract
    IBullaFrendLendV2 public bullaFrendLend;

    /// @notice Address of the BullaClaimV2 contract (for callback whitelisting)
    address public immutable bullaClaimV2;

    /// @notice Zodiac Roles Modifier for executing whitelisting calls
    IZodiacRoles public rolesModifier;

    /// @notice Role key that grants this factory permission to whitelist callbacks
    bytes32 public roleKey;
    
    /// @notice Protocol fee in basis points applied to all new pools
    uint16 public protocolFeeBps;

    /// @notice Counter for generating unique salts
    uint256 public poolNonce;

    /// @notice Mapping of allowed asset tokens for pool creation
    mapping(address => bool) public allowedAssets;

    /// @notice Fee required to create a new pool (in native ETH), used as anti-spam protection
    uint256 public poolCreationFee;

    /// @notice Expected length of BullaFactoringV2_1 init bytecode (creation code without constructor args)
    uint256 public initBytecodeLength;

    /// @notice Expected keccak256 hash of BullaFactoringV2_1 init bytecode
    bytes32 public expectedInitBytecodeHash;

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

    /// @notice Emitted when the Zodiac Roles configuration is updated
    event ZodiacRolesConfigChanged(address indexed rolesModifier, bytes32 roleKey);
    
    /// @notice Emitted when the protocol fee is updated
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);

    /// @notice Emitted when an asset is added to or removed from the whitelist
    event AssetWhitelistChanged(address indexed asset, bool allowed);

    /// @notice Emitted when the init bytecode verification config is updated
    event InitBytecodeConfigChanged(uint256 length, bytes32 hash);

    /// @notice Emitted when the pool creation fee is updated
    event PoolCreationFeeChanged(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when collected fees are withdrawn
    event FeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when callbacks are whitelisted for a new pool
    event CallbacksWhitelisted(address indexed pool);

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
    error CallbackWhitelistingFailed();
    error ZodiacRolesNotConfigured();
    error InvalidInitBytecode(bytes32 expected, bytes32 actual);
    error InitBytecodeNotConfigured();

    /// @notice Creates a new BullaFactoringFactoryV2_1
    /// @param _invoiceProviderAdapter Address of the invoice provider adapter
    /// @param _bullaFrendLend Address of the BullaFrendLend contract
    /// @param _bullaClaimV2 Address of the BullaClaimV2 contract
    /// @param _bullaDao Address of the factory owner (typically BullaDao), also becomes bullaDao for all created pools
    /// @param _protocolFeeBps Protocol fee in basis points
    /// @param _initBytecodeLength Expected length of BullaFactoringV2_1 init bytecode
    /// @param _expectedInitBytecodeHash Expected keccak256 hash of init bytecode
    constructor(
        address _invoiceProviderAdapter,
        address _bullaFrendLend,
        address _bullaClaimV2,
        address _bullaDao,
        uint16 _protocolFeeBps,
        uint256 _initBytecodeLength,
        bytes32 _expectedInitBytecodeHash
    ) Ownable(_bullaDao) {
        if (address(_invoiceProviderAdapter) == address(0)) revert InvalidAddress();
        if (address(_bullaFrendLend) == address(0)) revert InvalidAddress();
        if (_bullaClaimV2 == address(0)) revert InvalidAddress();
        if (_bullaDao == address(0)) revert InvalidAddress();
        if (_protocolFeeBps > 10000) revert InvalidPercentage();

        invoiceProviderAdapter = IInvoiceProviderAdapterV2(_invoiceProviderAdapter);
        bullaFrendLend = IBullaFrendLendV2(_bullaFrendLend);
        bullaClaimV2 = _bullaClaimV2;
        protocolFeeBps = _protocolFeeBps;
        initBytecodeLength = _initBytecodeLength;
        expectedInitBytecodeHash = _expectedInitBytecodeHash;
    }

    /// @notice Creates a new BullaFactoringV2_1 pool using CREATE2
    /// @dev Caller must provide creation bytecode with correct protocol parameters
    /// @dev Factory verifies bullaDao, protocolFee, invoiceAdapter, and bullaFrendLend after deployment
    /// @dev If Zodiac Roles is configured, automatically whitelists callbacks for the new pool
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

        // Verify init bytecode matches expected hash
        if (initBytecodeLength == 0 || expectedInitBytecodeHash == bytes32(0)) revert InitBytecodeNotConfigured();
        bytes32 actualHash;
        uint256 len = initBytecodeLength;
        assembly {
            // creationBytecode is a bytes memory, so data starts at offset 0x20
            actualHash := keccak256(add(creationBytecode, 0x20), len)
        }
        if (actualHash != expectedInitBytecodeHash) {
            revert InvalidInitBytecode(expectedInitBytecodeHash, actualHash);
        }

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

        // Verify deployed asset matches the declared asset parameter and is allowed
        address actualAsset = address(deployedPool.assetAddress());
        if (actualAsset != asset || !allowedAssets[actualAsset]) {
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

        // Whitelist callbacks via Zodiac Roles Modifier
        _whitelistCallbacks(pool);

        return pool;
    }

    /// @notice Internal function to whitelist callbacks for a new pool via Zodiac Roles
    /// @param pool The newly created pool address
    function _whitelistCallbacks(address pool) internal {
        if (address(rolesModifier) == address(0)) revert ZodiacRolesNotConfigured();

        // Callback selectors for BullaFactoringV2_1
        bytes4 onLoanOfferAcceptedSelector = bytes4(keccak256("onLoanOfferAccepted(uint256,uint256)"));
        bytes4 reconcileSingleInvoiceSelector = bytes4(keccak256("reconcileSingleInvoice(uint256)"));

        // Whitelist onLoanOfferAccepted callback on BullaFrendLend
        bool success1 = rolesModifier.execTransactionWithRole(
            address(bullaFrendLend),
            0, // value
            abi.encodeWithSignature(
                "addToCallbackWhitelist(address,bytes4)",
                pool,
                onLoanOfferAcceptedSelector
            ),
            IZodiacRoles.Operation.Call,
            roleKey,
            false // don't revert, check success
        );

        // Whitelist reconcileSingleInvoice callback on BullaClaimV2
        bool success2 = rolesModifier.execTransactionWithRole(
            bullaClaimV2,
            0, // value
            abi.encodeWithSignature(
                "addToPaidCallbackWhitelist(address,bytes4)",
                pool,
                reconcileSingleInvoiceSelector
            ),
            IZodiacRoles.Operation.Call,
            roleKey,
            false // don't revert, check success
        );

        if (!success1 || !success2) revert CallbackWhitelistingFailed();

        emit CallbacksWhitelisted(pool);
    }

    // ============================================================
    // Admin Functions
    // ============================================================

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

    /// @notice Configures Zodiac Roles Modifier for callback whitelisting
    /// @param _rolesModifier Address of the Zodiac Roles Modifier contract
    /// @param _roleKey The role key that grants permission to whitelist callbacks
    function setZodiacRolesConfig(IZodiacRoles _rolesModifier, bytes32 _roleKey) external onlyOwner {
        if (address(_rolesModifier) == address(0)) revert InvalidAddress();
        rolesModifier = _rolesModifier;
        roleKey = _roleKey;
        emit ZodiacRolesConfigChanged(address(_rolesModifier), _roleKey);
    }

    /// @notice Updates the protocol fee in basis points
    /// @param _newProtocolFeeBps The new protocol fee in basis points
    function setProtocolFeeBps(uint16 _newProtocolFeeBps) external onlyOwner {
        if (_newProtocolFeeBps > 10000) revert InvalidPercentage();
        uint16 oldProtocolFeeBps = protocolFeeBps;
        protocolFeeBps = _newProtocolFeeBps;
        emit ProtocolFeeBpsChanged(oldProtocolFeeBps, _newProtocolFeeBps);
    }

    /// @notice Updates the init bytecode verification config
    /// @dev Used when BullaFactoringV2_1 is recompiled with different settings
    /// @param _initBytecodeLength Expected length of init bytecode (creation code without constructor args)
    /// @param _expectedInitBytecodeHash Expected keccak256 hash of init bytecode
    function setInitBytecodeConfig(uint256 _initBytecodeLength, bytes32 _expectedInitBytecodeHash) external onlyOwner {
        initBytecodeLength = _initBytecodeLength;
        expectedInitBytecodeHash = _expectedInitBytecodeHash;
        emit InitBytecodeConfigChanged(_initBytecodeLength, _expectedInitBytecodeHash);
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
