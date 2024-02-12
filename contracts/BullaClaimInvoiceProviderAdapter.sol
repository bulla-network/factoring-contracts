// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceProviderAdapter.sol";
import "@bulla-network/contracts/interfaces/IBullaClaim.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract BullaClaimInvoiceProviderAdapter is IInvoiceProviderAdapter {
    IBullaClaim private bullaClaim;

    constructor(IBullaClaim _bullaClaimAddress) {
        bullaClaim = _bullaClaimAddress;
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory) {
        Claim memory claim = bullaClaim.getClaim(invoiceId);
        Invoice memory invoice = Invoice({
            faceValue: claim.claimAmount,
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