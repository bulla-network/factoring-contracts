// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IInvoiceProviderAdapter.sol";
import {IBullaClaimV2} from "bulla-contracts-v2/src/interfaces/IBullaClaimV2.sol";
import {IBullaClaimCore} from "bulla-contracts-v2/src/interfaces/IBullaClaimCore.sol";
import {Claim, Status} from "bulla-contracts-v2/src/types/Types.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {IBullaFrendLendV2, Loan} from "bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {IBullaInvoice, Invoice as BullaInvoice} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";

contract BullaClaimV2InvoiceProviderAdapterV2 is IInvoiceProviderAdapterV2 {
    IBullaClaimV2 private bullaClaimV2;
    IBullaFrendLendV2 private immutable bullaFrendLend;
    IBullaInvoice private immutable bullaInvoice;

    // Cache for controller addresses (immutable once set)
    mapping(uint256 => address) private controllerCache;
    mapping(uint256 => uint256) private impairmentGracePeriodCache;
    mapping(uint256 => bool) private isCached;
    
    error InexistentInvoice();
    error UnknownClaimType();

    constructor(address _bullaClaimV2Address, address _bullaFrendLend, address _bullaInvoice) {
        bullaClaimV2 = IBullaClaimV2(_bullaClaimV2Address);
        bullaFrendLend = IBullaFrendLendV2(_bullaFrendLend);
        bullaInvoice = IBullaInvoice(_bullaInvoice);
    }

    /// @notice Initializes the invoice cache
    /// @dev Sets the controller address for the invoice
    /// @param invoiceId The ID of the invoice
    function initializeInvoice(uint256 invoiceId) external {
        Claim memory claim = bullaClaimV2.getClaim(invoiceId);
        if (claim.creditor == address(0) && claim.debtor == address(0)) revert InexistentInvoice();

        controllerCache[invoiceId] = claim.controller;
        impairmentGracePeriodCache[invoiceId] = claim.impairmentGracePeriod;
        isCached[invoiceId] = true;
    }

    /// @notice Gets controller address, using cache
    /// @dev Reverts if invoice is not cached
    /// @param invoiceId The ID of the invoice
    /// @return controller The controller address
    function _getCachedController(uint256 invoiceId) private view returns (address controller) {
        // Check if cached
        if (isCached[invoiceId]) {
            return controllerCache[invoiceId];
        }
        
        revert InexistentInvoice();
    }

    function getInvoiceDetails(uint256 invoiceId) external view returns (Invoice memory) {
        address controller = _getCachedController(invoiceId);

        uint256 paidAmount;
        uint256 invoiceAmount;

        // Use cached controller for routing logic
        if (controller == address(0)) {
            Claim memory claim = bullaClaimV2.getClaim(invoiceId);

            paidAmount = claim.paidAmount;
            invoiceAmount = claim.claimAmount;

            Invoice memory invoice = Invoice({
                invoiceAmount: invoiceAmount,
                creditor: claim.creditor,
                debtor: claim.debtor,
                dueDate: claim.dueBy,
                tokenAddress: claim.token,
                paidAmount: paidAmount,
                isCanceled: claim.status == Status.Rejected || claim.status == Status.Rescinded,
                isPaid: claim.status == Status.Paid,
                impairmentGracePeriod: claim.impairmentGracePeriod
            });

            return invoice;
        } else if (controller == address(bullaFrendLend)) {
            Loan memory loan = bullaFrendLend.getLoan(invoiceId);
            // Cache interest computation state to avoid repeated access
            uint256 totalGrossInterestPaid = loan.interestComputationState.totalGrossInterestPaid;
            uint256 accruedInterest = loan.interestComputationState.accruedInterest;
            
            paidAmount = loan.paidAmount + totalGrossInterestPaid;
            invoiceAmount = loan.claimAmount + accruedInterest + totalGrossInterestPaid;

            Invoice memory invoice = Invoice({
                invoiceAmount: invoiceAmount,
                creditor: loan.creditor,
                debtor: loan.debtor,
                dueDate: loan.dueBy,
                tokenAddress: loan.token,
                paidAmount: paidAmount,
                isCanceled: loan.status == Status.Rejected || loan.status == Status.Rescinded,
                isPaid: loan.status == Status.Paid,
                impairmentGracePeriod: impairmentGracePeriodCache[invoiceId]
            });

            return invoice;
        } else if (controller == address(bullaInvoice)) {
            BullaInvoice memory _bullaInvoice = bullaInvoice.getInvoice(invoiceId);
            // Cache interest computation state to avoid repeated access
            uint256 totalGrossInterestPaid = _bullaInvoice.interestComputationState.totalGrossInterestPaid;
            uint256 accruedInterest = _bullaInvoice.interestComputationState.accruedInterest;
            
            paidAmount = _bullaInvoice.paidAmount + totalGrossInterestPaid;
            invoiceAmount = _bullaInvoice.claimAmount + accruedInterest + totalGrossInterestPaid;

            Invoice memory invoice = Invoice({
                invoiceAmount: invoiceAmount,
                creditor: _bullaInvoice.creditor,
                debtor: _bullaInvoice.debtor,
                dueDate: _bullaInvoice.dueBy,
                tokenAddress: _bullaInvoice.token,
                paidAmount: paidAmount,
                isCanceled: _bullaInvoice.status == Status.Rejected || _bullaInvoice.status == Status.Rescinded,
                isPaid: _bullaInvoice.status == Status.Paid,
                impairmentGracePeriod: impairmentGracePeriodCache[invoiceId]
            });

            return invoice;
        } else {
            revert UnknownClaimType();
        }
    }

    function getInvoiceContractAddress(uint256 tokenId) external view returns (address) {
        address controller = _getCachedController(tokenId);
        
        return controller == address(0) ? address(bullaClaimV2) : controller;
    }

    /// @notice Gets the underlying contract address and selector for impairing an invoice
    /// @param invoiceId The ID of the invoice to impair
    /// @return target The contract address to call
    /// @return selector The function selector to call
    /// @dev This function returns the target and selector so the caller can make the call directly with proper msg.sender
    function getImpairTarget(uint256 invoiceId) external view returns (address target, bytes4 selector) {
        address controller = _getCachedController(invoiceId);
        
        if (controller == address(0)) {
            // BullaClaimV2 - use impairClaim function
            return (address(bullaClaimV2), IBullaClaimCore.impairClaim.selector);
        } else if (controller == address(bullaFrendLend)) {
            // BullaFrendLend - use impairLoan function
            return (address(bullaFrendLend), IBullaFrendLendV2.impairLoan.selector);
        } else if (controller == address(bullaInvoice)) {
            // BullaInvoice - use impairInvoice function
            return (address(bullaInvoice), IBullaInvoice.impairInvoice.selector);
        } else {
            revert UnknownClaimType();
        }
    }
}
