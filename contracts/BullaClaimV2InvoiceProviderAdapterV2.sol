// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceProviderAdapter.sol";
import {IBullaClaimV2} from "bulla-contracts-v2/src/interfaces/IBullaClaimV2.sol";
import {Claim, Status} from "bulla-contracts-v2/src/types/Types.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {IBullaFrendLendV2, Loan} from "bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {IBullaInvoice, Invoice as BullaInvoice} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";

contract BullaClaimV2InvoiceProviderAdapterV2 is IInvoiceProviderAdapterV2 {
    IBullaClaimV2 private bullaClaimV2;
    IBullaFrendLendV2 private immutable bullaFrendLend;
    IBullaInvoice private immutable bullaInvoice;

    error InexistentInvoice();
    error UnknownClaimType();

    constructor(address _bullaClaimV2Address, address _bullaFrendLend, address _bullaInvoice) {
        bullaClaimV2 = IBullaClaimV2(_bullaClaimV2Address);
        bullaFrendLend = IBullaFrendLendV2(_bullaFrendLend);
        bullaInvoice = IBullaInvoice(_bullaInvoice);
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory) {
        Claim memory claim = bullaClaimV2.getClaim(invoiceId);
        if (claim.creditor == address(0) && claim.debtor == address(0)) revert InexistentInvoice();

        uint256 paidAmount;
        uint256 invoiceAmount;

        if (claim.controller == address(0)) {
            paidAmount = claim.paidAmount;
            invoiceAmount = claim.claimAmount;
        } else if (claim.controller == address(bullaFrendLend)) {
            Loan memory loan = bullaFrendLend.getLoan(invoiceId);
            paidAmount = loan.paidAmount + loan.interestComputationState.totalGrossInterestPaid;
            invoiceAmount = loan.claimAmount + loan.interestComputationState.accruedInterest + loan.interestComputationState.totalGrossInterestPaid;
        } else if (claim.controller == address(bullaInvoice)) {
            BullaInvoice memory _bullaInvoice = bullaInvoice.getInvoice(invoiceId);
            paidAmount = _bullaInvoice.paidAmount + _bullaInvoice.interestComputationState.totalGrossInterestPaid;
            invoiceAmount = _bullaInvoice.claimAmount + _bullaInvoice.interestComputationState.accruedInterest + _bullaInvoice.interestComputationState.totalGrossInterestPaid;
        } else {
            revert UnknownClaimType();
        }

        Invoice memory invoice = Invoice({
            invoiceAmount: invoiceAmount,
            creditor: claim.creditor,
            debtor: claim.debtor,
            dueDate: claim.dueBy,
            tokenAddress: claim.token,
            paidAmount: paidAmount,
            isCanceled: claim.status == Status.Rejected || claim.status == Status.Rescinded,
            isPaid: claim.status == Status.Paid
        });

        return invoice;
    }

    function getInvoiceContractAddress(uint256 tokenId) external view returns (address) {
        Claim memory claim = bullaClaimV2.getClaim(tokenId);
        
        return claim.controller == address(0) ? address(bullaClaimV2) : claim.controller;
    }
}
