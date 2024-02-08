// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IInvoiceProviderAdapter {

    struct Invoice {
        uint256 faceValue;
        address debtor;
        uint256 dueDate;
        address tokenAddress;
        uint256 paidAmount;
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory);
    function getClaimAddress() external view returns (address);
    function getInvoiceDetailsBatched(uint256[] calldata invoiceIds) external view returns (Invoice[] memory);
}