// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IInvoice {

    struct Invoice {
        uint256 faceValue;
        address originalCreditor;
        address debtor;
        uint256 dueDate;
        address tokenAddress;
        uint256 paidAmount;
    }

    function getInvoiceDetails(uint256[] calldata invoiceIds) external view returns (Invoice[] memory);
}