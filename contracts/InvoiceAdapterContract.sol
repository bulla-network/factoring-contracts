// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IInvoice.sol";
import "./mocks/MockBullaClaim.sol";
import "./interfaces/IBullaClaim.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract InvoiceAdapterContract is IInvoice {
    IBullaClaim private bullaClaim;

    constructor(IBullaClaim _bullaClaimAddress) {
        bullaClaim = _bullaClaimAddress;
    }

    function getInvoiceDetails(uint256[] calldata invoiceIds) external view override returns (Invoice[] memory) {
        Invoice[] memory invoices = new Invoice[](invoiceIds.length);

        for (uint i = 0; i < invoiceIds.length; i++) {
            Claim memory claim = bullaClaim.getClaim(invoiceIds[i]);
            address originalCreditor = IERC721(address(bullaClaim)).ownerOf(invoiceIds[i]);
            invoices[i] = Invoice({
                faceValue: claim.claimAmount,
                originalCreditor: originalCreditor,
                debtor: claim.debtor,
                dueDate: claim.dueBy,
                tokenAddress: claim.claimToken,
                paidAmount: claim.paidAmount
            });
        }

        return invoices;
    }
}