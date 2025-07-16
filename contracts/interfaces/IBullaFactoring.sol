// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./IInvoiceProviderAdapter.sol";
import "./IRedemptionQueue.sol";

/// @notice Interface for the Bulla Factoring contract
interface IBullaFactoringV2 {

    // Structs
    struct FeeParams {
        uint16 targetYieldBps;
        uint16 spreadBps;
        uint16 upfrontBps;
        uint16 protocolFeeBps;
        uint16 adminFeeBps;
        uint16 minDaysInterestApplied;
    }

    // The rest of the info can be retrieved from the loan offer
    struct PendingLoanOfferInfo {
        bool exists;
        uint256 offeredAt;
        uint256 principalAmount;
        uint256 termLength;
        FeeParams feeParams;
    }

    struct InvoiceApproval {
        bool approved;
        address creditor;
        uint256 validUntil;
        uint256 invoiceDueDate;
        uint256 fundedTimestamp;
        FeeParams feeParams;
        uint256 fundedAmountGross;
        uint256 fundedAmountNet;
        uint256 initialInvoiceValue; // takes into account the principal amount override and the initial paid amount. Do not subtract the initial paid amount from this value.
        uint256 initialPaidAmount;
        address receiverAddress;
    }

    struct Multihash {
        bytes32 hash;
        uint8 hashFunction;
        uint8 size;
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
        uint256 impairReserve;
        uint256 targetYieldBps;
    }

    struct ImpairmentDetails {
        uint256 gainAmount;
        uint256 lossAmount;
        bool isImpaired;
    }

    // Events
    event InvoiceApproved(uint256 indexed invoiceId, uint256 validUntil, FeeParams feeParams);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor, uint256 dueDate, uint16 upfrontBps);
    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event GracePeriodDaysChanged(uint256 newGracePeriodDays);
    event ApprovalDurationChanged(uint256 newDuration);
    event UnderwriterChanged(address indexed oldUnderwriter, address indexed newUnderwriter);
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoicePaid(uint256 indexed invoiceId, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee, uint256 fundedAmountNet, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoiceUnfactored(uint256 indexed invoiceId, address originalCreditor, int256 totalRefundOrPaymentAmount, uint256 interestToCharge, uint256 spreadAmount, uint256 protocolFee, uint256 adminFee);
    event DepositMadeWithAttachment(address indexed depositor, uint256 assets, uint256 shares, Multihash attachment);
    event SharesRedeemedWithAttachment(address indexed redeemer, uint256 shares, uint256 assets, Multihash attachment);
    event BullaDaoAddressChanged(address indexed oldAddress, address indexed newAddress);
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);
    event ProtocolFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event AdminFeeBpsChanged(uint16 indexed oldFeeBps, uint16 indexed newFeeBps);
    event AdminFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event SpreadGainsWithdrawn(address indexed owner, uint256 amount);
    event DepositPermissionsChanged(address newAddress);
    event RedeemPermissionsChanged(address newAddress);
    event FactoringPermissionsChanged(address newAddress);
    event InvoiceImpaired(uint256 indexed invoiceId, uint256 lossAmount, uint256 gainAmount);
    event ImpairReserveChanged(uint256 newImpairReserve);
    event TargetYieldChanged(uint16 newTargetYield);
    event RedemptionQueueChanged(address indexed oldQueue, address indexed newQueue);

    // Functions
    function approveInvoice(uint256 invoiceId, uint16 _interestApr, uint16 _spreadBps, uint16 _upfrontBps, uint16 minDaysInterestApplied, uint256 _principalAmountOverride) external;
    function pricePerShare() external view returns (uint256);
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps, address receiverAddress) external returns (uint256);
    function viewPoolStatus() external view returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices);
    function reconcileActivePaidInvoices() external;
    function setGracePeriodDays(uint256 _days) external;
    function setApprovalDuration(uint256 _duration) external;
    function assetAddress() external view returns (IERC20);

    // Redemption queue functions
    function redeemAndOrQueue(uint256 shares, address receiver, address _owner) external returns (uint256 redeemedAssets, uint256 queuedShares);
    function withdrawAndOrQueue(uint256 assets, address receiver, address _owner) external returns (uint256 redeemedShares, uint256 queuedAssets);
    function getRedemptionQueue() external view returns (IRedemptionQueue);
    function setRedemptionQueue(address _redemptionQueue) external;
}