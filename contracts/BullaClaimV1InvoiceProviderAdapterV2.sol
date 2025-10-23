// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceProviderAdapter.sol";
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract BullaClaimV1InvoiceProviderAdapterV2 is IInvoiceProviderAdapterV2 {
    IBullaClaim private bullaClaim;

    error InexistentInvoice();

    constructor(IBullaClaim _bullaClaimAddress) {
        bullaClaim = _bullaClaimAddress;
    }

    function initializeInvoice(uint256 invoiceId) external {
        // Nothing to do
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory) {
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        if (claim.claimToken == address(0)) revert InexistentInvoice();

        address creditor = IERC721(address(bullaClaim)).ownerOf(invoiceId);

        Invoice memory invoice = Invoice({
            invoiceAmount: claim.claimAmount,
            creditor: creditor,
            debtor: claim.debtor,
            dueDate: claim.dueBy,
            tokenAddress: claim.claimToken,
            paidAmount: claim.paidAmount,
            isCanceled: claim.status == Status.Rejected || claim.status == Status.Rescinded,
            isPaid: claim.status == Status.Paid,
            impairmentGracePeriod: 0 // V1 doesn't support impairment
        });

        return invoice;
    }

    function getInvoiceContractAddress(uint256) external view returns (address) {
        return address(bullaClaim);
    }

    function getImpairTarget(uint256 invoiceId) external view returns (address target, bytes4 selector) {
        // BullaClaimV1 doesn't support impairment, so return zero values
        return (address(0), bytes4(0));
    }
}