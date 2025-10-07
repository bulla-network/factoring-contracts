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
        bool isImpaired;
        bool isPaid;
    }

    function initializeInvoice(uint256 invoiceId) external;
    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory);
    function getInvoiceContractAddress(uint256 invoiceId) external view returns (address);
    
    /// @notice Gets the underlying contract address and selector for impairing an invoice
    /// @param invoiceId The ID of the invoice to impair
    /// @return target The contract address to call
    /// @return selector The function selector to call
    /// @dev This function returns the target and selector so the caller can make the call directly with proper msg.sender
    function getImpairTarget(uint256 invoiceId) external view returns (address target, bytes4 selector);
}