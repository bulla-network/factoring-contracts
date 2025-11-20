// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import {IBullaFactoringVault} from "./interfaces/IBullaFactoringVault.sol";
import "./interfaces/IRedemptionQueue.sol";
import "./Permissions.sol";
import "./RedemptionQueue.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

/// @title Bulla Factoring Vault
/// @author @solidoracle
/// @notice Vault that holds assets and manages deposits/redemptions for Bulla Factoring funds
contract BullaFactoringVault is ERC20, ERC4626, Ownable, IBullaFactoringVault {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Mapping of associated funds that can pull/push assets
    mapping(address => bool) public associatedFunds;
    
    /// @notice Address of the underlying asset token (e.g., USDC)
    IERC20 public assetAddress;
    
    /// @notice Permissions contracts for deposit and redemption
    Permissions public depositPermissions;
    Permissions public redeemPermissions;
    
    /// @notice Redemption queue contract for handling queued redemptions
    IRedemptionQueue public redemptionQueue;
    
    /// @notice Total deposits made to the vault
    uint256 private totalDeposits;
    
    /// @notice Total withdrawals from the vault
    uint256 private totalWithdrawals;
    
    /// @notice Total capital currently at risk (deployed to invoices)
    uint256 public atRiskCapital;
    
    /// @notice Total fees currently locked (withheld by funds)
    uint256 public lockedFees;
    
    /// @notice Total realized gains from returned invoices
    uint256 public realizedGains;
    
    /// @notice Mapping of fund address => total capital at risk for that fund
    mapping(address => uint256) public fundAtRiskCapital;
    
    /// @notice Mapping of fund address => invoice ID => capital amount deployed
    mapping(address => mapping(uint256 => uint256)) public invoiceCapitalDeployed;
    
    /// @notice Mapping of fund address => invoice ID => withheld fees amount
    mapping(address => mapping(uint256 => uint256)) public invoiceFeesLocked;
    
    /// @notice Aave v3 Pool contract
    IPool public aavePool;
    
    /// @notice Aave aToken (interest-bearing token) for the underlying asset
    IAToken public aToken;
    
    /// @notice Whether Aave integration is enabled
    bool public aaveEnabled;
    
    /// Errors
    error UnauthorizedDeposit(address caller);
    error InvalidAddress();
    error InsufficientBalance(uint256 available, uint256 required);
    error AaveNotEnabled();
    
    /// Events
    event AaveDeposit(uint256 amount);
    event AaveWithdraw(uint256 amount);
    event AaveConfigured(address indexed pool, address indexed aToken, bool enabled);
    
    /// @param _asset underlying supported stablecoin asset for deposit 
    /// @param _depositPermissions deposit permissions contract
    /// @param _redeemPermissions redeem permissions contract
    /// @param _tokenName name of the vault token
    /// @param _tokenSymbol symbol of the vault token
    /// @param _aavePool Aave v3 Pool contract address (optional, can be address(0))
    constructor(
        IERC20 _asset,
        Permissions _depositPermissions,
        Permissions _redeemPermissions,
        string memory _tokenName, 
        string memory _tokenSymbol,
        address _aavePool
    ) ERC20(_tokenName, _tokenSymbol) ERC4626(_asset) Ownable(_msgSender()) {
        assetAddress = _asset;
        depositPermissions = _depositPermissions;
        redeemPermissions = _redeemPermissions;
        redemptionQueue = new RedemptionQueue(msg.sender, address(this));
        
        // Configure Aave if provided
        if (_aavePool != address(0)) {
            _configureAave(_aavePool);
        }
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626, IERC20Metadata) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }
    
    /// @notice Returns the underlying asset address
    /// @return The asset token address
    function asset() public view override(ERC4626, IBullaFactoringVault) returns (address) {
        return super.asset();
    }

    /// @notice Modifier to restrict access to associated funds only
    modifier onlyAssociatedFund() {
        if (!associatedFunds[msg.sender]) revert UnauthorizedFund();
        _;
    }

    /// @notice Associate or disassociate a fund with this vault
    /// @param fund The address of the fund
    /// @param isAssociated Whether to associate or disassociate
    /// @dev Can only be called by the owner
    function setAssociatedFund(address fund, bool isAssociated) external onlyOwner {
        if (fund == address(0)) revert InvalidFundAddress();
        associatedFunds[fund] = isAssociated;
        emit FundAssociated(fund, isAssociated);
    }

    /// @notice Check if a fund is associated with this vault
    /// @param fund The address of the fund to check
    /// @return Whether the fund is associated
    function isAssociatedFund(address fund) external view returns (bool) {
        return associatedFunds[fund];
    }

    /// @notice Pull funds from the vault to a recipient (called by associated funds when funding an invoice)
    /// @param invoiceId The ID of the invoice being funded
    /// @param capitalAmount The amount of capital to deploy (fundedAmountNet)
    /// @param withheldFees The amount of fees to lock (spread + admin + protocol fees)
    /// @param to The address to send the assets to
    function pullFunds(uint256 invoiceId, uint256 capitalAmount, uint256 withheldFees, address to) external onlyAssociatedFund {
        uint256 totalRequired = capitalAmount + withheldFees;
        uint256 available = totalAssets();
        if (totalRequired > available) revert InsufficientBalance(available, totalRequired);
        
        // Track capital deployment and locked fees for this fund and invoice
        invoiceCapitalDeployed[msg.sender][invoiceId] = capitalAmount;
        atRiskCapital += capitalAmount;
        fundAtRiskCapital[msg.sender] += capitalAmount;
        
        invoiceFeesLocked[msg.sender][invoiceId] = withheldFees;
        lockedFees += withheldFees;
        
        // Withdraw from Aave if needed to ensure sufficient liquidity
        _ensureLiquidity(capitalAmount);
        
        // Only transfer the capital amount (fees stay locked in vault)
        assetAddress.safeTransfer(to, capitalAmount);
        
        emit FundsPulled(msg.sender, invoiceId, capitalAmount, withheldFees, to);
    }

    /// @notice Return funds to the vault (called by associated funds when invoice is paid/unfactored)
    /// @param invoiceId The ID of the invoice being returned
    /// @param gain The gain amount earned on this invoice (interest)
    function returnFunds(uint256 invoiceId, uint256 gain) external onlyAssociatedFund {
        // Get the original capital deployed and fees locked for this invoice
        uint256 capitalDeployed = invoiceCapitalDeployed[msg.sender][invoiceId];
        uint256 feesLocked = invoiceFeesLocked[msg.sender][invoiceId];
        if (capitalDeployed == 0) revert InvalidInvoice();
        
        // Calculate amount to transfer from fund (capital + gain, but NOT the fees which stay in fund)
        uint256 totalReturn = capitalDeployed + gain;
        
        // Transfer funds from the fund back to vault (capital + gain only)
        assetAddress.safeTransferFrom(msg.sender, address(this), totalReturn);
        
        // Update tracking - release the locked fees since they've been realized
        atRiskCapital -= capitalDeployed;
        fundAtRiskCapital[msg.sender] -= capitalDeployed;

        lockedFees -= feesLocked;
        realizedGains += gain;
        
        delete invoiceCapitalDeployed[msg.sender][invoiceId];
        delete invoiceFeesLocked[msg.sender][invoiceId];
        
        
        // Process redemption queue after funds are returned
        processRedemptionQueue();

        // Deposit idle funds into Aave
        _depositToAave();
        
        emit FundsReturned(msg.sender, invoiceId, capitalDeployed, gain);
    }

    /// @notice Calculates the capital account balance, including deposits, withdrawals, realized gains, and Aave yields
    /// @return The calculated capital account balance
    /// @dev This includes Aave interest automatically since aTokens appreciate in value
    function calculateCapitalAccount() public view override returns (uint256) {
        // Get the actual balance (vault + Aave), which includes all accrued Aave interest
        uint256 actualBalance = getTotalBalance();
        
        // Add back capital at risk and locked fees to get total capital account
        // Capital account = actual liquid balance + deployed capital + locked fees
        return actualBalance + atRiskCapital + lockedFees;
    }

    /// @notice Calculates the current price per share of the vault
    /// @return The current price per share, scaled to the underlying asset's decimal places
    function pricePerShare() public view override returns (uint256) {
        return previewRedeem(10**decimals());
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            return assets;
        }

        return assets.mulDiv(_totalSupply, calculateCapitalAccount(), rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            return shares;
        }

        return shares.mulDiv(calculateCapitalAccount(), _totalSupply, rounding);
    }

    /// @notice Helper function to handle the logic of depositing assets in exchange for vault shares
    /// @param receiver The address to receive the vault shares
    /// @param assets The amount of assets to deposit
    /// @return The number of shares issued for the deposit
    function deposit(uint256 assets, address receiver) public override(ERC4626, IERC4626) returns (uint256) {
        if (!depositPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        
        uint256 shares = super.deposit(assets, receiver);
        totalDeposits += assets;

        // Process redemption queue after deposit due to new liquidity
        processRedemptionQueue();

        // Deposit idle funds into Aave
        _depositToAave();
        
        return shares;
    }

    /// @notice Mint is disabled - use deposit() instead
    /// @dev Always reverts as this vault only supports deposits, not minting
    function mint(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert("Mint disabled - use deposit()");
    }

    /// @notice Calculates the available assets in the vault (including Aave deposits)
    /// @return The amount of assets available (total balance + Aave balance - capital at risk - locked fees)
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return calculateCapitalAccount() - atRiskCapital - lockedFees;
    }
    
    /// @notice Get the total balance including assets in Aave
    /// @return The total balance of assets (vault balance + Aave balance)
    function getTotalBalance() public view returns (uint256) {
        return assetAddress.balanceOf(address(this)) + _getAaveBalance();
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the vault
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() public view override returns (uint256) {
        return _maxRedeemOptimized(calculateCapitalAccount(), totalAssets());
    }
    
    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the vault
    /// @param _capitalAccount The capital account of the vault
    /// @param _totalAssets The total assets of the vault
    /// @return The maximum number of shares that can be redeemed
    function _maxRedeemOptimized(uint256 _capitalAccount, uint256 _totalAssets) private view returns (uint256) {
        if (_capitalAccount == 0) {
            return 0;
        }

        uint256 maxWithdrawableShares = convertToShares(_totalAssets);
        return maxWithdrawableShares;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the vault
    /// @param _owner The owner of the shares being redeemed
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem(address _owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxRedeem(_owner), maxRedeem());
    }

    /// @notice Calculates the maximum amount of assets that can be withdrawn
    /// @param _owner The owner of the assets to be withdrawn
    /// @return The maximum number of assets that can be withdrawn
    function maxWithdraw(address _owner) public view override(ERC4626, IERC4626) returns (uint256) {
        return Math.min(super.maxWithdraw(_owner), totalAssets());
    }

    /// @notice Updates the deposit permissions contract
    /// @param _newDepositPermissionsAddress The new deposit permissions contract address
    function setDepositPermissions(address _newDepositPermissionsAddress) external onlyOwner {
        depositPermissions = Permissions(_newDepositPermissionsAddress);
    }

    /// @notice Updates the redeem permissions contract
    /// @param _newRedeemPermissionsAddress The new redeem permissions contract address
    function setRedeemPermissions(address _newRedeemPermissionsAddress) external onlyOwner {
        redeemPermissions = Permissions(_newRedeemPermissionsAddress);
    }

    // ========== Redemption Queue Functions ==========

    /// @notice Redeem shares, queuing excess if insufficient liquidity
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param _owner The owner of the shares being redeemed
    /// @return The amount of assets redeemed
    function redeem(uint256 shares, address receiver, address _owner) public override(ERC4626, IERC4626) returns (uint256) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);

        uint256 sharesToRedeem = redemptionQueue.isQueueEmpty() ? Math.min(shares, maxRedeem(_owner)) : 0;
        uint256 redeemedAssets = 0;
        
        if (sharesToRedeem > 0) {
            // Calculate assets needed and ensure liquidity from Aave
            uint256 assetsNeeded = previewRedeem(sharesToRedeem);
            _ensureLiquidity(assetsNeeded);
            
            redeemedAssets = super.redeem(sharesToRedeem, receiver, _owner);
            totalWithdrawals += redeemedAssets;
        }

        uint256 queuedShares = shares - sharesToRedeem;
        if (queuedShares > 0) {
            // Queue the remaining shares for future redemption
            redemptionQueue.queueRedemption(_owner, receiver, queuedShares, 0);
        }
        
        return redeemedAssets;
    }

    /// @notice Withdraw assets, queuing excess if insufficient liquidity
    /// @param assets The amount of assets to withdraw
    /// @param receiver The address to receive the withdrawn assets
    /// @param _owner The owner of the shares being redeemed
    /// @return The amount of shares redeemed
    function withdraw(uint256 assets, address receiver, address _owner) public override(ERC4626, IERC4626) returns (uint256) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);
        
        uint256 assetsToWithdraw = redemptionQueue.isQueueEmpty() ? Math.min(assets, maxWithdraw(_owner)) : 0;
        uint256 redeemedShares = 0;
        
        if (assetsToWithdraw > 0) {
            // Ensure liquidity from Aave before withdrawing
            _ensureLiquidity(assetsToWithdraw);
            
            redeemedShares = super.withdraw(assetsToWithdraw, receiver, _owner);
            totalWithdrawals += assetsToWithdraw;
        }

        uint256 queuedAssets = assets - assetsToWithdraw;
        if (queuedAssets > 0) {
            // Queue the remaining assets for future withdrawal
            redemptionQueue.queueRedemption(_owner, receiver, 0, queuedAssets);
        }
        
        return redeemedShares;
    }

    /// @notice Process queued redemptions when liquidity becomes available
    function processRedemptionQueue() public {
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        if (redemption.owner == address(0)) return;

        // Memory-optimized: Calculate capital account once and derive total assets
        uint256 _capitalAccount = calculateCapitalAccount();
        uint256 _totalAssets = _capitalAccount - atRiskCapital - lockedFees;
        uint256 maxRedeemableShares = _maxRedeemOptimized(_capitalAccount, _totalAssets);
        
        while (redemption.owner != address(0) && _totalAssets > 0) {
            uint256 amountProcessed = 0;
            
            if (redemption.shares > 0) {
                // This is a share-based redemption
                uint256 sharesToRedeem = Math.min(redemption.shares, maxRedeemableShares);
                
                if (sharesToRedeem > 0) {
                    // Pre-validation: Check if owner has enough shares
                    uint256 ownerBalance = balanceOf(redemption.owner);
                    
                    if (ownerBalance >= sharesToRedeem) {
                        // Owner has sufficient funds - process redemption
                        uint256 assets = previewRedeem(sharesToRedeem);
                        
                        // Ensure liquidity from Aave before withdrawing
                        _ensureLiquidity(assets);
                        
                        _withdraw(redemption.owner, redemption.receiver, redemption.owner, assets, sharesToRedeem);
                        totalWithdrawals += assets;
                        amountProcessed = sharesToRedeem;
                        _totalAssets -= assets;
                        maxRedeemableShares -= sharesToRedeem;
                    } else {
                        // Owner doesn't have sufficient funds - remove from queue
                        amountProcessed = redemption.shares;
                    }
                } else {
                    // No liquidity available - stop processing
                    break;
                }
            } else if (redemption.assets > 0) {
                // This is an asset-based withdrawal
                uint256 maxWithdrawableAssets = maxWithdraw(redemption.owner);
                uint256 assetsToWithdraw = Math.min(redemption.assets, maxWithdrawableAssets);
                
                if (assetsToWithdraw > 0) {
                    // Pre-validation: Check if owner has enough shares for withdrawal
                    uint256 sharesToBurn = previewWithdraw(assetsToWithdraw);
                    uint256 ownerBalance = balanceOf(redemption.owner);
                    
                    if (ownerBalance >= sharesToBurn) {
                        // Owner has sufficient funds - process withdrawal
                        // Ensure liquidity from Aave before withdrawing
                        _ensureLiquidity(assetsToWithdraw);
                        
                        _withdraw(redemption.owner, redemption.receiver, redemption.owner, assetsToWithdraw, sharesToBurn);
                        totalWithdrawals += assetsToWithdraw;
                        amountProcessed = assetsToWithdraw;
                        _totalAssets -= assetsToWithdraw;
                        maxRedeemableShares -= sharesToBurn;
                    } else {
                        // Owner doesn't have sufficient funds - remove from queue
                        amountProcessed = redemption.assets;
                    }
                } else {
                    // No liquidity available - stop processing
                    break;
                }
            }
            
            if (amountProcessed > 0) {
                // Remove the processed redemption from the queue
                redemption = redemptionQueue.removeAmountFromFirstOwner(amountProcessed);
            } else {
                // Can't process this redemption, stop processing
                break;
            }
        }
    }

    /// @notice Get the redemption queue contract
    /// @return The redemption queue contract interface
    function getRedemptionQueue() external view returns (IRedemptionQueue) {
        return redemptionQueue;
    }

    /// @notice Set the redemption queue contract
    /// @param _redemptionQueue The new redemption queue contract address
    function setRedemptionQueue(address _redemptionQueue) external onlyOwner {
        if (_redemptionQueue == address(0)) revert InvalidAddress();
        redemptionQueue = IRedemptionQueue(_redemptionQueue);
    }

    // ========== Aave Integration Functions ==========

    /// @notice Configure Aave integration
    /// @param _aavePool Address of the Aave v3 Pool contract
    function configureAave(address _aavePool) external onlyOwner {
        _configureAave(_aavePool);
    }

    /// @notice Enable or disable Aave integration
    /// @param _enabled Whether Aave integration should be enabled
    function setAaveEnabled(bool _enabled) external onlyOwner {
        if (_enabled && address(aavePool) == address(0)) revert AaveNotEnabled();
        
        // If disabling, withdraw all funds from Aave
        if (!_enabled && aaveEnabled) {
            _withdrawFromAave(type(uint256).max);
        }
        
        aaveEnabled = _enabled;
        emit AaveConfigured(address(aavePool), address(aToken), _enabled);
    }

    /// @notice Internal function to configure Aave
    /// @param _aavePool Address of the Aave v3 Pool contract
    function _configureAave(address _aavePool) internal {
        aavePool = IPool(_aavePool);
        
        // Get the aToken address from Aave
        DataTypes.ReserveData memory reserveData = aavePool.getReserveData(address(assetAddress));
        aToken = IAToken(reserveData.aTokenAddress);
        
        // Approve Aave pool to spend our underlying asset
        assetAddress.safeIncreaseAllowance(address(aavePool), type(uint256).max);
        
        aaveEnabled = true;
        emit AaveConfigured(_aavePool, address(aToken), true);
    }

    /// @notice Get the current balance of aTokens (representing underlying assets in Aave)
    /// @return The balance of aTokens held by this vault
    function _getAaveBalance() internal view returns (uint256) {
        if (!aaveEnabled || address(aToken) == address(0)) {
            return 0;
        }
        return aToken.balanceOf(address(this));
    }

    /// @notice Deposit idle assets into Aave to earn yield
    /// @dev This is called automatically after deposits and fund returns
    function _depositToAave() internal {
        if (!aaveEnabled) return;
        
        uint256 idleBalance = assetAddress.balanceOf(address(this));
        
        // Deposit all idle funds to Aave - we can withdraw anytime via _ensureLiquidity()
        if (idleBalance > 0) {
            aavePool.supply(address(assetAddress), idleBalance, address(this), 0);
            emit AaveDeposit(idleBalance);
        }
    }

    /// @notice Withdraw assets from Aave when liquidity is needed
    /// @param amount The amount to withdraw (use type(uint256).max to withdraw all)
    function _withdrawFromAave(uint256 amount) internal {
        if (!aaveEnabled) return;
        
        uint256 aaveBalance = _getAaveBalance();
        if (aaveBalance == 0) return;
        
        uint256 withdrawAmount = amount == type(uint256).max ? aaveBalance : Math.min(amount, aaveBalance);
        
        if (withdrawAmount > 0) {
            uint256 withdrawn = aavePool.withdraw(address(assetAddress), withdrawAmount, address(this));
            emit AaveWithdraw(withdrawn);
        }
    }
    
    /// @notice Internal helper to ensure sufficient liquidity by withdrawing from Aave if needed
    /// @param assetsNeeded The amount of assets needed for the operation
    function _ensureLiquidity(uint256 assetsNeeded) internal {
        uint256 vaultBalance = assetAddress.balanceOf(address(this));
        if (vaultBalance < assetsNeeded) {
            _withdrawFromAave(assetsNeeded - vaultBalance);
        }
    }
}

