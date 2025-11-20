// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IRedemptionQueue.sol";

/// @notice Interface for the Bulla Factoring Vault contract
/// @dev Vault handles deposit/redemption and holds pool assets
interface IBullaFactoringVault is IERC4626 {
    
    // Events
    event FundAssociated(address indexed fund, bool isAssociated);
    event FundsPulled(address indexed fund, uint256 indexed invoiceId, uint256 capitalAmount, uint256 withheldFees, address to);
    event FundsReturned(address indexed fund, uint256 indexed invoiceId, uint256 capitalReturned, uint256 gain);
    
    // Errors
    error UnauthorizedFund();
    error InvalidFundAddress();
    error InvalidInvoice();
    
    /// @notice Pull funds from the vault to a recipient (called by associated funds when funding an invoice)
    /// @param invoiceId The ID of the invoice being funded
    /// @param capitalAmount The amount of capital to deploy (fundedAmountNet)
    /// @param withheldFees The amount of fees to lock (spread + admin + protocol fees)
    /// @param to The address to send the assets to
    function pullFunds(uint256 invoiceId, uint256 capitalAmount, uint256 withheldFees, address to) external;
    
    /// @notice Return funds to the vault (called by associated funds when invoice is paid/unfactored)
    /// @param invoiceId The ID of the invoice being returned
    /// @param gain The gain amount earned on this invoice (can be 0 or positive)
    function returnFunds(uint256 invoiceId, uint256 gain) external;
    
    /// @notice Check if a fund is associated with this vault
    /// @param fund The address of the fund to check
    /// @return Whether the fund is associated
    function isAssociatedFund(address fund) external view returns (bool);
    
    /// @notice Associate or disassociate a fund with this vault
    /// @param fund The address of the fund
    /// @param isAssociated Whether to associate or disassociate
    /// @dev Can only be called by the owner
    function setAssociatedFund(address fund, bool isAssociated) external;
    
    /// @notice Get the total capital at risk for a specific fund
    /// @param fund The address of the fund
    /// @return The amount of capital currently at risk for that fund
    function fundAtRiskCapital(address fund) external view returns (uint256);
    
    /// @notice Get the underlying asset address
    /// @return The asset token address
    function asset() external view returns (address);
    
    /// @notice Calculates the capital account balance
    /// @return The calculated capital account balance
    function calculateCapitalAccount() external view returns (uint256);
    
    /// @notice Calculates the current price per share of the vault
    /// @return The current price per share
    function pricePerShare() external view returns (uint256);
    
    /// @notice Calculates the maximum amount of shares that can be redeemed
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() external view returns (uint256);
    
    /// @notice Get the redemption queue contract
    /// @return The redemption queue contract interface
    function getRedemptionQueue() external view returns (IRedemptionQueue);
    
    /// @notice Process queued redemptions when liquidity becomes available
    function processRedemptionQueue() external;
    
    /// @notice Get the total balance including assets in Aave
    /// @return The total balance of assets (vault balance + Aave balance)
    function getTotalBalance() external view returns (uint256);
}

