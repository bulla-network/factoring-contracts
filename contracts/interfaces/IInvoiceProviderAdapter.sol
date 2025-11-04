// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Interface for the invoice provider adapter contract
interface IInvoiceProviderAdapterV2 {

    struct Invoice {
        uint256 invoiceAmount;
        uint256 dueDate;
        uint256 paidAmount;
        uint256 impairmentGracePeriod;
        address creditor;           // 20 bytes
        bool isCanceled;            // 1 byte
        bool isPaid;                // 1 byte - packed in slot 4 (22 bytes total)
        address debtor;             // 20 bytes - slot 5
        address tokenAddress;       // 20 bytes - slot 6
    }

    function initializeInvoice(uint256 invoiceId) external;
    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory);
    function getInvoiceContractAddress(uint256 invoiceId) external view returns (address);
    function getSetPaidInvoiceTarget(uint256 invoiceId) external view returns (address target, bytes4 selector);
}