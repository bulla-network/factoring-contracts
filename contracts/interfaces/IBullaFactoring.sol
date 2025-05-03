// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./IInvoiceProviderAdapter.sol";

/// @notice Interface for the Bulla Factoring contract
interface IBullaFactoringV2 {
    // Structs
    struct InvoiceApproval {
        bool approved;
        IInvoiceProviderAdapterV2.Invoice invoiceSnapshot;
        uint256 validUntil;
        uint256 fundedTimestamp;
        uint16 interestApr;
        uint16 upfrontBps;
        uint256 fundedAmountGross;
        uint256 fundedAmountNet;
        uint16 minDaysInterestApplied;
        uint256 initialFullInvoiceAmount;
        uint256 initialPaidAmount;
        uint16 protocolFeeBps;
        uint16 adminFeeBps;
    }

    struct Multihash {
        bytes32 hash;
        uint8 hashFunction;
        uint8 size;
    }

    struct FundInfo {
        string name;
        uint256 creationTimestamp;
        uint256 deployedCapital;
        uint16 adminFeeBps;
        uint256 impairReserve;
        uint256 targetYieldBps;
        int256 pnl;
    }

    struct ImpairmentDetails {
        uint256 gainAmount;
        uint256 lossAmount;
        bool isImpaired;
    }

    // Events
    event InvoiceApproved(uint256 indexed invoiceId, uint16 interestApr, uint16 upfrontBps, uint256 validUntil, uint16 minDays);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor);
    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event GracePeriodDaysChanged(uint256 newGracePeriodDays);
    event ApprovalDurationChanged(uint256 newDuration);
    event UnderwriterChanged(address indexed oldUnderwriter, address indexed newUnderwriter);
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoicePaid(uint256 indexed invoiceId, uint256 trueInterest, uint256 trueProtocolFee, uint256 adminFee, uint256 fundedAmountNet, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoiceUnfactored(uint256 indexed invoiceId, address originalCreditor, int256 totalRefundOrPaymentAmount, uint interestToCharge);
    event BullaDaoAddressChanged(address indexed oldAddress, address indexed newAddress);
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);
    event ProtocolFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event AdminFeeBpsChanged(uint16 indexed oldFeeBps, uint16 indexed newFeeBps);
    event AdminFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event DepositPermissionsChanged(address newAddress);
    event FactoringPermissionsChanged(address newAddress);
    event InvoiceImpaired(uint256 indexed invoiceId, uint256 lossAmount, uint256 gainAmount);
    event ImpairReserveChanged(uint256 newImpairReserve);
    event TargetYieldChanged(uint16 newTargetYield);

    // Functions
    function approveInvoice(uint256 invoiceId, uint16 _apr, uint16 _bps, uint16 minDaysInterestApplied) external;
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps) external returns (uint256);
    function viewPoolStatus() external view returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices);
    function reconcileActivePaidInvoices() external;
    function setGracePeriodDays(uint256 _days) external;
    function setApprovalDuration(uint256 _duration) external;
}