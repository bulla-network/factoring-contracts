// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Interface for the invoice provider adapter contract
interface IInvoiceProviderAdapterV2 {

    struct Invoice {
        uint256 invoiceAmount;
        address creditor;
        address debtor;
        uint256 dueDate;
        address tokenAddress;
        uint256 paidAmount;
        bool isCanceled;
        bool isPaid;
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory);
    function getInvoiceContractAddress(uint256 invoiceId) external view returns (address);
}