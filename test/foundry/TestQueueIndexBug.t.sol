// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IRedemptionQueue} from "../../contracts/interfaces/IRedemptionQueue.sol";
import {RedemptionQueue} from "../../contracts/RedemptionQueue.sol";

/**
 * @title TestQueueIndexBug
 * @notice Test to validate the bug where cancelQueuedRedemption(0) removes the wrong queue item
 * @dev This test demonstrates the issue described: "removing the first item from the queue but this only works 
 *      if the queue has been recently compacted. If we look at the FIFO queue and assume the first redemption 
 *      request can be satisfied but the second cannot due to insufficient funds, this will not remove the 
 *      correct request and prevent queue processing."
 */
contract TestQueueIndexBug is CommonSetup {
    
    // Test addresses
    address alice_investor = address(0x100);
    address bob_investor = address(0x200);
    address charlie_investor = address(0x300);
    
    function setUp() public override {
        super.setUp();
        
        // Grant permissions to test investors
        depositPermissions.allow(alice_investor);
        depositPermissions.allow(bob_investor);
        depositPermissions.allow(charlie_investor);
        redeemPermissions.allow(alice_investor);
        redeemPermissions.allow(bob_investor);
        redeemPermissions.allow(charlie_investor);
        factoringPermissions.allow(alice_investor);
        factoringPermissions.allow(bob_investor);
        factoringPermissions.allow(charlie_investor);
        
        // Give test users assets
        deal(address(asset), alice_investor, 10000000);
        deal(address(asset), bob_investor, 10000000);
        deal(address(asset), charlie_investor, 10000000);
    }
    
    /**
     * @notice Test that demonstrates the queue index bug
     * @dev This test creates a scenario where:
     *      1. Multiple redemptions are queued
     *      2. The first redemption is processed (moving head pointer)
     *      3. A subsequent redemption fails due to insufficient owner funds
     *      4. The code incorrectly cancels index 0 instead of the current head position
     */
    function testQueueIndexBugWhenHeadIsNotZero() public {
        // Step 1: Set up initial deposits
        uint256 depositAmount = 1000000; // 1M units
        
        // Alice deposits and gets shares
        vm.startPrank(alice_investor);
        asset.approve(address(bullaFactoring), depositAmount);
        uint256 aliceShares = bullaFactoring.deposit(depositAmount, alice_investor);
        vm.stopPrank();
        
        // // Bob deposits and gets shares
        // vm.startPrank(bob_investor);
        // asset.approve(address(bullaFactoring), depositAmount);
        // uint256 bobShares = bullaFactoring.deposit(depositAmount, bob_investor);
        // vm.stopPrank();

        // Step 2: Fund invoices to reduce liquidity and make redemptions queue
        console.log("Total assets before funding:", bullaFactoring.totalAssets());
        
        // Create and fund a large invoice to eliminate most liquidity
        vm.prank(alice_investor);
        uint256 invoiceId = createClaim(alice_investor, bob_investor, 1000000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0);
        vm.prank(alice_investor);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(alice_investor);
        bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        
        console.log("Available liquidity after deployment:", bullaFactoring.maxRedeem());
        
        // Step 3: Queue multiple redemption requests (all will be queued due to insufficient liquidity)
        vm.startPrank(alice_investor);
        uint256 aliceRedeemed = bullaFactoring.redeem(aliceShares, alice_investor, alice_investor);
        vm.stopPrank();
        
        // vm.startPrank(bob_investor);
        // uint256 bobRedeemed = bullaFactoring.redeem(bobShares, bob_investor, bob_investor);
        // vm.stopPrank();
        
        console.log("Alice redeemed:", aliceRedeemed);
        
        // Verify some redemptions are queued (limited liquidity available)
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Some redemptions should be queued");
        
        // Check queue state
        IRedemptionQueue.QueuedRedemption memory nextRedemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        console.log("Next redemption owner:", nextRedemption.owner);
        assertNotEq(nextRedemption.owner, address(0), "Queue should not be empty");
        
        // Step 4: Pay invoice to restore liquidity
        vm.startPrank(bob_investor);
        // approve payment
        asset.approve(address(bullaClaim), 1000000);
        bullaClaim.payClaim(invoiceId, 1000000);
        vm.stopPrank();
        
        // Store state before processing
        uint256 queueLengthBefore = bullaFactoring.getRedemptionQueue().getQueueLength();
        console.log("Queue length before processing:", queueLengthBefore);
        
        // Get the redemption at index 0 (Alice's processed redemption)
        IRedemptionQueue.QueuedRedemption memory redemptionAtIndex0 = bullaFactoring.getRedemptionQueue().getQueuedRedemption(0);
        console.log("Redemption at index 0 owner:", redemptionAtIndex0.owner);
        
        // Manually reconcile paid invoices before second redemption (since redeem now blocks when active paid invoices exist)
        bullaFactoring.reconcileActivePaidInvoices();

        // THIS MOVES THE HEAD to index 1
        // this is a second redemption, it will fail. This will cause the deposit to fail next.
        vm.prank(alice_investor);
        bullaFactoring.redeem(aliceShares, alice_investor, alice_investor);

        // Bob deposits, but no longer fails after the code change
        vm.startPrank(bob_investor);
        asset.approve(address(bullaFactoring), depositAmount);
        // vm.expectRevert(RedemptionQueue.RedemptionAlreadyCancelled.selector);
        bullaFactoring.deposit(depositAmount, bob_investor);
        vm.stopPrank();
    }
}
