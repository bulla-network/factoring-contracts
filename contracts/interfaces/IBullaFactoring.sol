// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./IInvoiceProviderAdapter.sol";
import "./IRedemptionQueue.sol";
import "./IInvoiceProviderAdapter.sol";

/// @notice Interface for the Bulla Factoring contract
interface IBullaFactoringV2_2 {

    // Structs
    struct FeeParams {
        uint16 targetYieldBps;
        uint16 spreadBps;
        uint16 upfrontBps;
        uint16 protocolFeeBps;
        uint16 adminFeeBps;
    }

    // The rest of the info can be retrieved from the loan offer
    struct PendingLoanOfferInfo {
        uint256 offeredAt;
        uint256 principalAmount;
        uint256 termLength;
        bool exists;            // 1 byte
        FeeParams feeParams;    // 12 bytes - packed in slot 3 (13 bytes total)
    }

    struct InvoiceApproval {
        bool approved;              // 1 byte
        address creditor;           // 20 bytes - packed in slot 0 (21 bytes total)
        uint256 validUntil;
        uint256 invoiceDueDate;
        uint256 impairmentDate;
        uint256 fundedTimestamp;
        uint256 fundedAmountGross;
        uint256 fundedAmountNet;
        uint256 initialInvoiceValue; // takes into account the principal amount override and the initial paid amount. Do not subtract the initial paid amount from this value.
        uint256 initialPaidAmount;
        uint256 protocolFee;
        address receiverAddress;    // 20 bytes
        FeeParams feeParams;        // 12 bytes - packed in slot 11 (32 bytes total)
        uint256 perSecondInterestRateRay;  // Pre-calculated per-second interest in RAY units (1e27) for high precision (slot 12)
    }

    struct FundInfo {
        string name;
        uint256 creationTimestamp;
        uint256 fundBalance;
        uint256 deployedCapital;
        uint256 capitalAccount;
        uint256 price;
        uint256 tokensAvailableForRedemption;
        uint16 adminFeeBps;
        uint256 targetYieldBps;
    }

    struct ImpairmentInfo {
        bool isImpaired;
        uint256 purchasePrice;
        uint256 paidAmountAtImpairment;
    }

    struct ApproveInvoiceParams {
        uint256 invoiceId;
        uint16 targetYieldBps;
        uint16 spreadBps;
        uint16 upfrontBps;
        uint256 initialInvoiceValueOverride;
    }

    struct FundInvoiceParams {
        uint256 invoiceId;
        uint16 factorerUpfrontBps;
        uint8 receiverAddressIndex;
    }

    // Events
    event InvoiceApproved(uint256 indexed invoiceId, uint256 validUntil, FeeParams feeParams);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor, uint256 dueDate, uint16 upfrontBps, uint256 protocolFee, address fundsReceiver);
    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event GracePeriodDaysChanged(uint256 newGracePeriodDays);
    event ApprovalDurationChanged(uint256 newDuration);
    event UnderwriterChanged(address indexed oldUnderwriter, address indexed newUnderwriter);
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoicePaid(uint256 indexed invoiceId, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee, uint256 fundedAmountNet, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoiceUnfactored(uint256 indexed invoiceId, address originalCreditor, int256 totalRefundOrPaymentAmount, uint256 interestToCharge, uint256 spreadAmount, uint256 adminFee, bool unfactoredByOwner);

    event BullaDaoAddressChanged(address indexed oldAddress, address indexed newAddress);
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);
    event ProtocolFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event AdminFeeBpsChanged(uint16 indexed oldFeeBps, uint16 indexed newFeeBps);
    event AdminFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event DepositPermissionsChanged(address newAddress);
    event RedeemPermissionsChanged(address newAddress);
    event FactoringPermissionsChanged(address newAddress);
    event TargetYieldChanged(uint16 newTargetYield);
    event RedemptionQueueChanged(address indexed oldQueue, address indexed newQueue);

    // Insurance events
    event InsurerChanged(address indexed oldInsurer, address indexed newInsurer);
    event InsuranceParamsChanged(uint16 insuranceFeeBps, uint16 impairmentGrossGainBps, uint16 recoveryProfitRatioBps);
    event InsuranceWithdrawn(address indexed insurer, uint256 amount);
    event InvoiceImpaired(uint256 indexed invoiceId, uint256 outstandingBalance, uint256 impairmentGrossGain, uint256 impairmentNetGain);
    event InsuranceRecovered(uint256 indexed invoiceId, uint256 amount);
    event ImpairedInvoiceReconciled(uint256 indexed invoiceId, uint256 amountRecovered, uint256 insuranceShare, uint256 investorShare);

    // Functions
    function approveInvoices(ApproveInvoiceParams[] calldata params) external;
    function pricePerShare() external view returns (uint256);
    function fundInvoices(FundInvoiceParams[] calldata params, address[] calldata receiverAddresses) external returns (uint256[] memory);
    function viewPoolStatus(uint256 offset, uint256 limit) external view returns (uint256[] memory impairedInvoiceIds, bool hasMore);
    function reconcileSingleInvoice(uint256 invoiceId) external;
    function setGracePeriodDays(uint256 _days) external;
    function setApprovalDuration(uint256 _duration) external;
    function assetAddress() external view returns (IERC20);

    // Redemption queue functions
    function getRedemptionQueue() external view returns (IRedemptionQueue);
    function setRedemptionQueue(address _redemptionQueue) external;
    
    // Preview functions
    function previewUnfactor(uint256 invoiceId) external view returns (int256 totalRefundOrPaymentAmount);
    
    // Pending loan offer management
    function clearStalePendingLoanOffers(uint256 offset, uint256 limit) external returns (uint256 processed, uint256 removed, uint256 remaining);

    // Active invoices
    function getActiveInvoices() external view returns (uint256[] memory);
    function getActiveInvoicesCount() external view returns (uint256);
    function getActiveInvoiceAt(uint256 index) external view returns (uint256);

    // Insurance functions
    function setInsurer(address _newInsurer) external;
    function setInsuranceParams(uint16 _insuranceFeeBps, uint16 _impairmentGrossGainBps, uint16 _recoveryProfitRatioBps) external;
    function withdrawInsuranceBalance() external;
    function previewImpair(uint256 invoiceId) external view returns (uint256 outstandingBalance, uint256 impairmentGrossGain, uint256 adminFeeOwed, uint256 impairmentNetGain, uint256 outOfPocketCost, uint256 currentPaidAmount);
    function impairInvoice(uint256 invoiceId) external;
}