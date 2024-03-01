// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./IInvoiceProviderAdapter.sol";

interface IBullaFactoring {
    // Structs
    struct InvoiceApproval {
        bool approved;
        IInvoiceProviderAdapter.Invoice invoiceSnapshot;
        uint256 validUntil;
    }

    // Events
    event InvoiceApproved(uint256 indexed invoiceId);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor);
    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event DepositMade(address indexed depositor, uint256 assets, uint256 sharesIssued);
    event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 assets);
    event FundingPercentageChanged(uint256 newFundingPercentage);
    event GracePeriodDaysChanged(uint256 newGracePeriodDays);
    event ApprovalDurationChanged(uint256 newDuration);
    event UnderwriterChanged(address indexed oldUnderwriter, address indexed newUnderwriter);
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);
    event KickbackPercentageChanged(uint256 newKickbackPercentageBps);
    event InvoiceUnfactored(uint256 indexed invoiceId, address originalCreditor);

    // Functions
    function approveInvoice(uint256 invoiceId) external;
    function calculateRealizedGainLoss() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function fundInvoice(uint256 invoiceId) external;
    function viewPoolStatus() external view returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices);
    function reconcileActivePaidInvoices() external;
    function setFundingPercentage(uint256 _fundingPercentage) external;
    function setGracePeriodDays(uint256 _days) external;
    function setApprovalDuration(uint256 _duration) external;
}