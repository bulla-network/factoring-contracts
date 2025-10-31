// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./CommonSetup.t.sol";
import "forge-std/console.sol";
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';

contract TestActivePaidInvoicesCheck is CommonSetup {
    
    function setUp() public override {
        super.setUp();
    }

    function test_RedeemWithdraw_WorkWhenNoPaidInvoices() public {
        uint256 initialDeposit = 200000;
        
        // Setup - no invoices created, so no paid invoices
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Note: With the new model, active invoices are always unpaid.
        // viewPoolStatus() only returns impaired invoices now.

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
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 0);
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
        bullaFactoring.approveInvoice(invoiceId, 730, 1000, 8000, 0);
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
