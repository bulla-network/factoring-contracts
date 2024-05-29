// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceProviderAdapter.sol";
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {console} from "../lib/forge-std/src/console.sol";

contract BullaClaimInvoiceProviderAdapter is IInvoiceProviderAdapter {
    IBullaClaim private bullaClaim;

    error InexistentInvoice();

    constructor(IBullaClaim _bullaClaimAddress) {
        bullaClaim = _bullaClaimAddress;
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory) {
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        if (claim.claimToken == address(0)) revert InexistentInvoice();

        address invoiceContractAddress = this.getInvoiceContractAddress();
        address creditor = IERC721(invoiceContractAddress).ownerOf(invoiceId);

        Invoice memory invoice = Invoice({
            faceValue: claim.claimAmount,
            creditor: creditor,
            debtor: claim.debtor,
            dueDate: claim.dueBy,
            tokenAddress: claim.claimToken,
            paidAmount: claim.paidAmount,
            isCanceled: claim.status == Status.Rejected || claim.status == Status.Rescinded
        });

        return invoice;
    }

    function getInvoiceContractAddress() external view returns (address) {
        return address(bullaClaim);
    }
}