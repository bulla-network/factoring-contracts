// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IRedemptionQueue} from "../../contracts/interfaces/IRedemptionQueue.sol";

/**
 * @title TestAutomaticRedemptionQueueProcessing
 * @notice Tests automatic processRedemptionQueue calls in deposit, reconcileSingleInvoice, and unfactorInvoice
 * @dev Verifies that queued redemptions are automatically processed when liquidity becomes available
 */
contract TestAutomaticRedemptionQueueProcessing is CommonSetup {
    
    event RedemptionProcessed(
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assets,
        uint256 queueIndex
    );

    function setUp() public override {
        super.setUp();
        
        // Grant additional permissions
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
        factoringPermissions.allow(alice);
        factoringPermissions.allow(charlie);
        
        vm.prank(charlie);
        asset.approve(address(bullaFactoring), type(uint256).max);
        
        vm.prank(alice);
        asset.approve(address(bullaClaim), type(uint256).max);
    }

    // ============================================
    // Helper Functions
    // ============================================

    /// @notice Helper to setup a scenario with queued redemptions
    /// @return invoiceId The funded invoice ID
    /// @return queuedShares The number of shares queued for redemption
    function setupQueuedRedemption() internal returns (uint256 invoiceId, uint256 queuedShares) {
        // 1. Alice deposits
        uint256 depositAmount = 100000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // 2. Fund an invoice to tie up capital
        vm.prank(bob);
        invoiceId = createClaim(bob, alice, 90000, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // 3. Alice tries to redeem all shares - should queue
        vm.startPrank(alice);
        queuedShares = bullaFactoring.balanceOf(alice);
        bullaFactoring.redeem(queuedShares, alice, alice);
        vm.stopPrank();
        
        // Verify redemption was queued
        uint256 queueLength = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLength, 1, "Should have 1 queued redemption");
        
        return (invoiceId, queuedShares);
    }

    // ============================================
    // 1. Tests for Automatic Processing on deposit()
    // ============================================

    function testDeposit_AutomaticallyProcessesQueue() public {
        (uint256 invoiceId, uint256 queuedShares) = setupQueuedRedemption();
        
        uint256 aliceSharesBefore = bullaFactoring.balanceOf(alice);
        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        
        // Charlie deposits - should trigger automatic queue processing
        uint256 charlieDepositAmount = 50000;
        vm.prank(charlie);
        vm.expectEmit(true, true, false, false);
        emit RedemptionProcessed(alice, alice, 0, 0, 0); // We expect some redemption to be processed
        bullaFactoring.deposit(charlieDepositAmount, charlie);
        
        // Check if Alice's queued redemption was partially or fully processed
        uint256 aliceSharesAfter = bullaFactoring.balanceOf(alice);
        uint256 aliceAssetsAfter = asset.balanceOf(alice);
        
        // Alice should have received some assets back
        assertGt(aliceAssetsAfter, aliceAssetsBefore, "Alice should have received assets from queue processing");
    }

    function testDeposit_ProcessesMultipleQueuedRedemptions() public {
        // 1. Alice and Bob deposit
        vm.prank(alice);
        bullaFactoring.deposit(100000, alice);
        
        vm.prank(bob);
        bullaFactoring.deposit(100000, bob);
        
        // 2. Fund an invoice to tie up most capital
        vm.prank(charlie);
        uint256 invoiceId = createClaim(charlie, alice, 180000, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, 10000, 0);
        
        vm.startPrank(charlie);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // 3. Both Alice and Bob queue redemptions
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaFactoring.redeem(bullaFactoring.balanceOf(bob), bob, bob);
        vm.stopPrank();
        
        uint256 queueLength = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLength, 2, "Should have 2 queued redemptions");
        
        // 4. Charlie deposits - should process queue
        vm.prank(charlie);
        bullaFactoring.deposit(50000, charlie);
        
        // At least one redemption should be processed (FIFO order)
        uint256 queueLengthAfter = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLengthAfter, 1, "Queue should have fewer items after deposit");
    }

    // ============================================
    // 2. Tests for Automatic Processing on reconcileSingleInvoice()
    // ============================================

    function testReconcileSingleInvoice_AutomaticallyProcessesQueue() public {
        (uint256 invoiceId, uint256 queuedShares) = setupQueuedRedemption();
        
        uint256 queueLengthBefore = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLengthBefore, 1, "Should have 1 queued redemption before payment");
        
        // Pay the invoice
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(alice);
        uint256 invoiceAmount = 90000;
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();
        
        // Invoice payment triggers reconcileSingleInvoice callback, which should process queue
        // Queue should be fully or partially processed
        uint256 queueLengthAfter = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLengthAfter, 0, "Queue should be processed");
    }

    // ============================================
    // 3. Tests for Automatic Processing on unfactorInvoice()
    // ============================================

    function testUnfactorInvoice_AutomaticallyProcessesQueue() public {
        (uint256 invoiceId, uint256 queuedShares) = setupQueuedRedemption();
        
        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        
        // Bob (original creditor) unfactors the invoice
        vm.startPrank(bob);
        // Bob needs to pay back the funded amount (approximately)
        // For unfactoring, the creditor needs to have sufficient funds
        int256 refundAmount = bullaFactoring.previewUnfactor(invoiceId);
        if (refundAmount > 0) {
            asset.approve(address(bullaFactoring), uint256(refundAmount));
        }
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        // Queue should be processed after unfactoring
        uint256 queueLengthAfter = bullaFactoring.getRedemptionQueue().getQueueLength();
        
        // Queue might be fully or partially processed depending on how much capital returned
        assertEq(queueLengthAfter, 0, "Queue should be processed");
    }

    function testUnfactorInvoice_ProcessesQueueWithMultipleInvestors() public {
        // Setup: Two investors deposit
        vm.prank(alice);
        bullaFactoring.deposit(100000, alice);
        
        vm.prank(charlie);
        bullaFactoring.deposit(100000, charlie);
        
        // Bob funds an invoice
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 90000, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Both investors queue redemptions
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        bullaFactoring.redeem(bullaFactoring.balanceOf(charlie), charlie, charlie);
        vm.stopPrank();
        
        uint256 queueLengthAfterQueuing = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertTrue(queueLengthAfterQueuing > 0, "Should have queued redemptions");
        
        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        
        // Bob unfactors the invoice
        vm.startPrank(bob);
        int256 refundAmount = bullaFactoring.previewUnfactor(invoiceId);
        if (refundAmount > 0) {
            asset.approve(address(bullaFactoring), uint256(refundAmount));
        }
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        // At least one redemption should be processed (FIFO)
        uint256 queueLengthAfter = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLengthAfter, 0, "Queue should be processed");
    }

    function testUnfactorInvoice_ImpairedInvoiceByOwner_ProcessesQueue() public {
        // Setup queued redemption
        (uint256 invoiceId, ) = setupQueuedRedemption();
        
        // Make invoice impaired by waiting past due date + impairment grace period
        // dueBy is 30 days from now, impairment grace period is another 60 days
        vm.warp(block.timestamp + 100 days);
        
        // Verify invoice is impaired
        (uint256[] memory impairedInvoices, ) = bullaFactoring.viewPoolStatus(0, 10);
        require(impairedInvoices.length > 0, "Invoice should be impaired");
        
        // Pool owner unfactors impaired invoice
        vm.startPrank(bullaFactoring.owner());
        int256 refundAmount = bullaFactoring.previewUnfactor(invoiceId);
        if (refundAmount > 0) {
            asset.mint(bullaFactoring.owner(), uint256(refundAmount));
            asset.approve(address(bullaFactoring), uint256(refundAmount));
        }
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        // Queue should be processed
        uint256 queueLengthAfter = bullaFactoring.getRedemptionQueue().getQueueLength();
        assertEq(queueLengthAfter, 0, "Queue should be processed after unfactoring");
    }

    // ============================================
    // 4. Edge Cases
    // ============================================

    function testAutomaticProcessing_InsufficientLiquidityAfterOperation() public {
        (uint256 invoiceId, ) = setupQueuedRedemption();
        
        // Charlie deposits a tiny amount - not enough to process queue
        vm.prank(charlie);
        bullaFactoring.deposit(100, charlie);
        
        // Queue should still exist (not enough liquidity to process)
        uint256 queueLength = bullaFactoring.getRedemptionQueue().getQueueLength();
        // Queue length depends on whether the small deposit was enough to process anything
        assertEq(queueLength, 1, "Queue handling should not fail");
    }
}

