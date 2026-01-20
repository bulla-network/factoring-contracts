// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BullaFactoring.sol";
import "./DepositPermissions.sol";
import "./FactoringPermissions.sol";
import "./interfaces/IInvoiceProviderAdapter.sol";
import {IBullaFrendLendV2} from "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";

/// @title Bulla Factoring Factory V2.1
/// @author Bulla Network
/// @notice Factory contract for deploying new BullaFactoringV2_1 pools with pre-configured settings
/// @dev Enables dynamic subgraph indexing of new pools through emitted events
contract BullaFactoringFactoryV2_1 is Ownable {
    /// @notice Address of the invoice provider adapter used for all pools
    IInvoiceProviderAdapterV2 public invoiceProviderAdapter;
    
    /// @notice Address of the BullaFrendLend contract
    IBullaFrendLendV2 public bullaFrendLend;
    
    /// @notice Protocol fee in basis points applied to all new pools
    uint16 public protocolFeeBps;

    /// @notice Array of all pools created by this factory
    address[] public pools;

    /// @notice Mapping of allowed asset tokens for pool creation
    mapping(address => bool) public allowedAssets;

    /// @notice Fee required to create a new pool (in native ETH), used as anti-spam protection
    uint256 public poolCreationFee;

    /// @notice Emitted when a new pool is created
    /// @param pool Address of the newly created pool
    /// @param owner Address of the pool owner
    /// @param asset Address of the underlying asset
    /// @param poolName Display name of the pool
    /// @param tokenName ERC20 token name
    /// @param tokenSymbol ERC20 token symbol
    /// @param depositPermissions Address of the deposit permissions contract
    /// @param redeemPermissions Address of the redeem permissions contract
    /// @param factoringPermissions Address of the factoring permissions contract
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

    /// @notice Internal function to deploy a pool with given permissions
    /// @dev Shared logic between createPool and createPoolWithPermissions
    function _deployPool(
        IERC20 asset,
        address underwriter,
        uint16 adminFeeBps,
        string memory poolName,
        uint16 targetYieldBps,
        string memory tokenName,
        string memory tokenSymbol,
        Permissions _depositPermissions,
        Permissions _redeemPermissions,
        Permissions _factoringPermissions
    ) internal returns (address pool) {
        if (!allowedAssets[address(asset)]) revert AssetNotAllowed(address(asset));
        if (underwriter == address(0)) revert InvalidAddress();
        if (address(_depositPermissions) == address(0)) revert InvalidAddress();
        if (address(_redeemPermissions) == address(0)) revert InvalidAddress();
        if (address(_factoringPermissions) == address(0)) revert InvalidAddress();
        if (adminFeeBps > 10000) revert InvalidPercentage();
        if (targetYieldBps > 10000) revert InvalidPercentage();

        // Deploy the pool (owner() is used as bullaDao for the pool)
        BullaFactoringV2_1 newPool = new BullaFactoringV2_1(
            asset,
            invoiceProviderAdapter,
            bullaFrendLend,
            underwriter,
            _depositPermissions,
            _redeemPermissions,
            _factoringPermissions,
            owner(),
            protocolFeeBps,
            adminFeeBps,
            poolName,
            targetYieldBps,
            tokenName,
            tokenSymbol
        );

        // Transfer pool ownership to the caller
        newPool.transferOwnership(msg.sender);

        pool = address(newPool);
        pools.push(pool);

        emit PoolCreated(
            pool,
            msg.sender,
            address(asset),
            poolName,
            tokenName,
            tokenSymbol,
            address(_depositPermissions),
            address(_redeemPermissions),
            address(_factoringPermissions)
        );

        return pool;
    }

    /// @notice Creates a new BullaFactoringV2_1 pool
    /// @dev Deploys new DepositPermissions and FactoringPermissions contracts for the pool
    /// @dev depositPermissions == redeemPermissions by default to avoid surprises
    /// @param asset The underlying asset token (e.g., USDC)
    /// @param underwriter Address of the underwriter who can approve invoices
    /// @param adminFeeBps Admin fee in basis points
    /// @param poolName Display name of the pool
    /// @param targetYieldBps Target yield in basis points
    /// @param tokenName ERC20 token name for the pool shares
    /// @param tokenSymbol ERC20 token symbol for the pool shares
    /// @param initialDepositors Array of addresses to whitelist for deposits/redeems
    /// @param initialFactorers Array of addresses to whitelist for factoring
    /// @return pool Address of the newly created pool
    /// @return depositRedeemPermissions Address of the deposit/redeem permissions contract
    /// @return factoringPermissions Address of the factoring permissions contract
    function createPool(
        IERC20 asset,
        address underwriter,
        uint16 adminFeeBps,
        string memory poolName,
        uint16 targetYieldBps,
        string memory tokenName,
        string memory tokenSymbol,
        address[] calldata initialDepositors,
        address[] calldata initialFactorers
    ) external payable returns (address pool, address depositRedeemPermissions, address factoringPermissions) {
        // Check pool creation fee (must be exact)
        if (msg.value != poolCreationFee) revert IncorrectFee(poolCreationFee, msg.value);

        // Deploy permissions contracts (factory is initial owner)
        DepositPermissions _depositRedeemPermissions = new DepositPermissions();
        FactoringPermissions _factoringPermissions = new FactoringPermissions();

        // Whitelist initial depositors before transferring ownership
        for (uint256 i = 0; i < initialDepositors.length; i++) {
            _depositRedeemPermissions.allow(initialDepositors[i]);
        }

        // Whitelist initial factorers before transferring ownership
        for (uint256 i = 0; i < initialFactorers.length; i++) {
            _factoringPermissions.allow(initialFactorers[i]);
        }

        // Transfer ownership of permissions to caller
        _depositRedeemPermissions.transferOwnership(msg.sender);
        _factoringPermissions.transferOwnership(msg.sender);

        // Deploy pool using shared logic (depositPermissions == redeemPermissions)
        pool = _deployPool(
            asset,
            underwriter,
            adminFeeBps,
            poolName,
            targetYieldBps,
            tokenName,
            tokenSymbol,
            Permissions(address(_depositRedeemPermissions)),
            Permissions(address(_depositRedeemPermissions)),
            Permissions(address(_factoringPermissions))
        );

        depositRedeemPermissions = address(_depositRedeemPermissions);
        factoringPermissions = address(_factoringPermissions);

        return (pool, depositRedeemPermissions, factoringPermissions);
    }

    /// @notice Creates a new BullaFactoringV2_1 pool with custom permissions contracts
    /// @dev Uses pre-deployed permissions contracts instead of creating new ones
    /// @param asset The underlying asset token (e.g., USDC)
    /// @param underwriter Address of the underwriter who can approve invoices
    /// @param adminFeeBps Admin fee in basis points
    /// @param poolName Display name of the pool
    /// @param targetYieldBps Target yield in basis points
    /// @param tokenName ERC20 token name for the pool shares
    /// @param tokenSymbol ERC20 token symbol for the pool shares
    /// @param _depositPermissions Address of the deposit permissions contract
    /// @param _redeemPermissions Address of the redeem permissions contract
    /// @param _factoringPermissions Address of the factoring permissions contract
    /// @return pool Address of the newly created pool
    function createPoolWithPermissions(
        IERC20 asset,
        address underwriter,
        uint16 adminFeeBps,
        string memory poolName,
        uint16 targetYieldBps,
        string memory tokenName,
        string memory tokenSymbol,
        Permissions _depositPermissions,
        Permissions _redeemPermissions,
        Permissions _factoringPermissions
    ) external payable returns (address pool) {
        // Check pool creation fee (must be exact)
        if (msg.value != poolCreationFee) revert IncorrectFee(poolCreationFee, msg.value);

        return _deployPool(
            asset,
            underwriter,
            adminFeeBps,
            poolName,
            targetYieldBps,
            tokenName,
            tokenSymbol,
            _depositPermissions,
            _redeemPermissions,
            _factoringPermissions
        );
    }

    /// @notice Returns the total number of pools created by this factory
    /// @return The number of pools
    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @notice Returns all pools created by this factory
    /// @return Array of pool addresses
    function getAllPools() external view returns (address[] memory) {
        return pools;
    }

    /// @notice Updates the invoice provider adapter
    /// @param _newAdapter The new invoice provider adapter address
    function setInvoiceProviderAdapter(IInvoiceProviderAdapterV2 _newAdapter) external onlyOwner {
        if (address(_newAdapter) == address(0)) revert InvalidAddress();
        address oldAdapter = address(invoiceProviderAdapter);
        invoiceProviderAdapter = _newAdapter;
        emit InvoiceProviderAdapterChanged(oldAdapter, address(_newAdapter));
    }

    /// @notice Updates the BullaFrendLend address
    /// @param _newBullaFrendLend The new BullaFrendLend address
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
}
