// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./CommonSetup.t.sol";
import "forge-std/console.sol";
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';

contract TestActivePaidInvoicesCheck is CommonSetup {
    
    function setUp() public override {
        super.setUp();
    }

    function test_Redeem_RevertWhenActivePaidInvoicesExist() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 30, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay the invoice - this creates a paid invoice that needs reconciliation
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before reconciliation");

        // Try to redeem - should revert due to active paid invoices
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 2;
        
        vm.expectRevert(BullaFactoringV2_1.ActivePaidInvoicesExist.selector);
        bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // After reconciliation, redeem should work
        bullaFactoring.reconcileActivePaidInvoices();
        
        vm.startPrank(alice);
        uint256 redeemedAssets = bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();
        
        assertGt(redeemedAssets, 0, "Should have redeemed assets after reconciliation");
    }

    function test_Withdraw_RevertWhenActivePaidInvoicesExist() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 30, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay the invoice - this creates a paid invoice that needs reconciliation
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before reconciliation");

        // Try to withdraw - should revert due to active paid invoices
        vm.startPrank(alice);
        uint256 maxWithdraw = bullaFactoring.maxWithdraw(alice);
        uint256 assetsToWithdraw = maxWithdraw / 2;
        
        vm.expectRevert(BullaFactoringV2_1.ActivePaidInvoicesExist.selector);
        bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        // After reconciliation, withdraw should work
        bullaFactoring.reconcileActivePaidInvoices();
        
        vm.startPrank(alice);
        uint256 withdrawnShares = bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();
        
        assertGt(withdrawnShares, 0, "Should have withdrawn shares after reconciliation");
    }

    function test_ProcessRedemptionQueue_RevertWhenActivePaidInvoicesExist() public {
        uint256 initialDeposit = 200000;  
        uint256 invoiceAmount = 100000;
        
        // Setup - Alice deposits and Bob creates invoice
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Fund the invoice to reduce available liquidity
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 30, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue a redemption (should be queued due to insufficient liquidity)
        vm.startPrank(alice);
        uint256 maxRedeemShares = bullaFactoring.maxRedeem(alice);
        uint256 sharesToRedeem = maxRedeemShares + 1000; // More than available
        bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify redemption was queued
        IRedemptionQueue.QueuedRedemption memory queuedRedemption = bullaFactoring.redemptionQueue().getNextRedemption();
        assertEq(queuedRedemption.owner, alice, "Redemption should be queued for Alice");

        // Pay the invoice - this creates a paid invoice that needs reconciliation
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before reconciliation");

        // Try to process redemption queue - should revert due to active paid invoices
        vm.expectRevert(BullaFactoringV2_1.ActivePaidInvoicesExist.selector);
        bullaFactoring.processRedemptionQueue();

        // After reconciliation, processing queue should work
        bullaFactoring.reconcileActivePaidInvoices();
        
        // Now processing should succeed
        bullaFactoring.processRedemptionQueue();
        
        // Verify the queue was processed (queue should now be empty or have fewer items)
        IRedemptionQueue.QueuedRedemption memory newQueuedRedemption = bullaFactoring.redemptionQueue().getNextRedemption();
        // Since we processed the queue, the next redemption should be different or empty
        assertTrue(
            newQueuedRedemption.owner == address(0) || newQueuedRedemption.shares < queuedRedemption.shares,
            "Queue should have been processed"
        );
    }

    function test_RedeemWithdraw_WorkWhenNoPaidInvoices() public {
        uint256 initialDeposit = 200000;
        
        // Setup - no invoices created, so no paid invoices
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Verify no paid invoices exist
        (uint256[] memory paidInvoices, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 0, "Should have no paid invoices");

        // Redeem should work fine when no paid invoices exist
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 4;
        uint256 redeemedAssets = bullaFactoring.redeem(sharesToRedeem, alice, alice);
        assertGt(redeemedAssets, 0, "Should have redeemed assets when no paid invoices exist");

        // Withdraw should also work fine
        uint256 assetsToWithdraw = 10000;
        uint256 withdrawnShares = bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        assertGt(withdrawnShares, 0, "Should have withdrawn shares when no paid invoices exist");
        vm.stopPrank();
    }

    function test_ProcessRedemptionQueue_WorkWhenNoPaidInvoices() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 150000; // Larger than deposit to force queuing
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);  
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Fund invoice to reduce liquidity
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 30, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue a large redemption
        vm.startPrank(alice);
        uint256 maxRedeemShares = bullaFactoring.maxRedeem(alice);
        uint256 sharesToRedeem = maxRedeemShares + 1000;
        bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify redemption was queued
        IRedemptionQueue.QueuedRedemption memory queuedRedemption = bullaFactoring.redemptionQueue().getNextRedemption();
        assertEq(queuedRedemption.owner, alice, "Redemption should be queued for Alice");

        // Verify no paid invoices exist (invoice not paid yet)
        (uint256[] memory paidInvoices, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 0, "Should have no paid invoices");

        // Process redemption queue should work when no paid invoices exist
        // (even though there might not be enough liquidity to process everything)
        bullaFactoring.processRedemptionQueue();

        // The function should complete without reverting, regardless of whether
        // anything was actually processed due to liquidity constraints
        assertTrue(true, "processRedemptionQueue should complete when no paid invoices exist");
    }

    function test_RedeemWithdraw_WorkAfterReconciliation() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Setup and create paid invoice scenario
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 30, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay the invoice
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Reconcile the paid invoice
        bullaFactoring.reconcileActivePaidInvoices();

        // Verify no paid invoices remain
        (uint256[] memory paidInvoices, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 0, "Should have no paid invoices after reconciliation");

        // Now redeem and withdraw should work normally
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 4;
        uint256 redeemedAssets = bullaFactoring.redeem(sharesToRedeem, alice, alice);
        assertGt(redeemedAssets, 0, "Should redeem successfully after reconciliation");

        uint256 assetsToWithdraw = 10000;
        uint256 withdrawnShares = bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        assertGt(withdrawnShares, 0, "Should withdraw successfully after reconciliation");
        vm.stopPrank();
    }
}
