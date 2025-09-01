// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "contracts/interfaces/IBullaFactoring.sol";
import {CreateClaimParams, ClaimBinding} from "bulla-contracts-v2/src/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title TestUnfactoringTriggersReconciliation
 * @notice Tests whether unfactoring an invoice triggers reconciliation of paid invoices
 * @dev This test validates that when one invoice is unfactored, any paid but unreconciled invoices get reconciled
 */
contract TestUnfactoringTriggersReconciliation is CommonSetup {

    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event InvoicePaid(
        uint256 indexed invoiceId,
        uint256 trueInterest,
        uint256 trueSpreadAmount,
        uint256 trueProtocolFee,
        uint256 trueAdminFee,
        uint256 fundedAmountNet,
        uint256 kickbackAmount,
        address indexed receiverAddress
    );

    function setUp() public override {
        super.setUp();
        // Add factoring pool to feeExemption whitelist
        feeExemptionWhitelist.allow(address(bullaFactoring));
    }

    function test_UnfactoringTriggersReconciliationOfPaidInvoices() public {
        uint256 invoiceAmount1 = 100000; // First invoice: $100,000
        uint256 invoiceAmount2 = 75000;  // Second invoice: $75,000
        dueBy = block.timestamp + 60 days;

        // Alice deposits funds to the pool
        uint256 initialDeposit = 400000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates two invoices
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount1, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount2, dueBy);
        vm.stopPrank();

        // Underwriter approves both invoices
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Bob funds both invoices
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();

        // Wait 30 days
        vm.warp(block.timestamp + 30 days);

        // Alice pays the first invoice but does NOT trigger reconciliation
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount1);
        bullaClaim.payClaim(invoiceId1, invoiceAmount1);
        vm.stopPrank();

        // Verify that the first invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid but unreconciled invoice");
        assertEq(paidInvoicesBefore[0], invoiceId1, "First invoice should be the paid one");

        // Verify no gain has been recorded yet (indicating no reconciliation)
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(invoiceId1);
        assertEq(gainBefore, 0, "Should have no recorded gain before reconciliation");

        // Record price per share before unfactoring
        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();

        // Bob decides to unfactor the second invoice
        // This should trigger reconciliation of the first (paid) invoice
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), type(uint256).max); // Approve max for unfactoring cost
        
        // Expect the reconciliation event for the first invoice during unfactoring
        vm.expectEmit(true, false, false, false);
        emit ActivePaidInvoicesReconciled(new uint256[](1)); // Should reconcile the paid invoice
        
        bullaFactoring.unfactorInvoice(invoiceId2);
        vm.stopPrank();

        // Verify the second invoice was unfactored (ownership returned to Bob)
        assertEq(IERC721(address(bullaClaim)).ownerOf(invoiceId2), bob, "Second invoice should be returned to Bob");

        // Verify Bob paid for unfactoring
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        assertLt(bobBalanceAfter, bobBalanceBefore, "Bob should have paid to unfactor the second invoice");

        // CRITICAL TEST: Verify that the first invoice was reconciled during unfactoring
        (uint256[] memory paidInvoicesAfter, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesAfter.length, 0, "Should have no paid invoices after reconciliation");

        // Verify gain was recorded for the first invoice (indicating reconciliation occurred)
        uint256 gainAfter = bullaFactoring.paidInvoicesGain(invoiceId1);
        assertGt(gainAfter, 0, "Should have recorded gain after reconciliation of first invoice");

        // Verify price per share increased due to reconciliation
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to reconciliation");

        console.log("Test Results:");
        console.log("- Invoice 1 (paid): Gain recorded =", gainAfter);
        console.log("- Invoice 2 (unfactored): Returned to Bob");
        console.log("- Price per share increased from", pricePerShareBefore, "to", pricePerShareAfter);
        console.log("- Paid invoices before unfactoring:", paidInvoicesBefore.length);
        console.log("- Paid invoices after unfactoring:", paidInvoicesAfter.length);
    }
}
