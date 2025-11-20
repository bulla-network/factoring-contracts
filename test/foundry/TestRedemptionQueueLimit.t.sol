// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IRedemptionQueue} from "../../contracts/interfaces/IRedemptionQueue.sol";

/**
 * @title TestRedemptionQueueLimit
 * @notice Tests for redemption queue size limits and RedemptionQueueFull error
 * @dev Tests the maximum queue size feature and active queue length tracking
 */
contract TestRedemptionQueueLimit is CommonSetup {
    
    // Error selectors
    error RedemptionQueueFull();
    
    function testDefaultMaxQueueSize() public view {
        uint256 maxSize = vault.getRedemptionQueue().getMaxQueueSize();
        assertEq(maxSize, 500, "Default max queue size should be 500");
    }

    function testSetMaxQueueSize() public {
        IRedemptionQueue queue = vault.getRedemptionQueue();
        
        // Set new max size
        vm.prank(bullaFactoring.owner());
        queue.setMaxQueueSize(1000);
        
        uint256 newMaxSize = queue.getMaxQueueSize();
        assertEq(newMaxSize, 1000, "Max queue size should be updated to 1000");
    }

    function testSetMaxQueueSizeOnlyOwner() public {
        IRedemptionQueue queue = vault.getRedemptionQueue();
        
        // Try to set as non-owner (should fail)
        vm.prank(alice);
        vm.expectRevert();
        queue.setMaxQueueSize(1000);
    }

    function testQueueRedemptionIncrementsLength() public {
        // Setup: Create pool with funds
        uint256 depositAmount = 100000;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Tie up capital so redemption is queued
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 95000, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue redemption
        vm.startPrank(alice);
        uint256 shares = vault.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 queueLength = vault.getRedemptionQueue().getQueueLength();
        assertEq(queueLength, 1, "Queue length should be 1 after queuing one redemption");
    }

    function testCancelQueuedRedemptionDecrementsLength() public {
        // Setup: Create pool and queue a redemption
        uint256 depositAmount = 100000;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Tie up capital so redemption is queued
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 95000, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue redemption
        vm.startPrank(alice);
        uint256 shares = vault.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 lengthBefore = vault.getRedemptionQueue().getQueueLength();
        assertEq(lengthBefore, 1, "Queue length should be 1 before cancellation");

        // Cancel the queued redemption at index 0
        vm.startPrank(alice);
        vault.getRedemptionQueue().cancelQueuedRedemption(0);
        vm.stopPrank();

        uint256 lengthAfter = vault.getRedemptionQueue().getQueueLength();
        assertEq(lengthAfter, 0, "Queue length should be 0 after cancellation");
    }

    function testProcessRedemptionDecrementsLength() public {
        // Setup: Create pool and queue a redemption
        uint256 depositAmount = 100000;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Tie up capital
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 95000, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue redemption
        vm.startPrank(alice);
        uint256 shares = vault.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 lengthBefore = vault.getRedemptionQueue().getQueueLength();
        assertEq(lengthBefore, 1, "Queue length should be 1");

        // Free up capital and process queue
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 100000);
        bullaClaim.payClaim(invoiceId, 95000);
        vm.stopPrank();

        vault.processRedemptionQueue();

        uint256 lengthAfter = vault.getRedemptionQueue().getQueueLength();
        assertEq(lengthAfter, 0, "Queue length should be 0 after processing");
    }

    function testRedemptionQueueFullError() public {
        // Set a very low max queue size for testing
        vm.prank(bullaFactoring.owner());
        vault.getRedemptionQueue().setMaxQueueSize(2);

        // Setup: Create initial pool
        uint256 initialDeposit = 100000;
        vm.startPrank(alice);
        asset.approve(address(vault), initialDeposit);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Tie up capital completely
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 98000, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue 2 redemptions from existing balance
        vm.startPrank(alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vault.redeem(aliceShares / 3, alice, alice); // First redemption
        vault.redeem(aliceShares / 3, alice, alice); // Second redemption (replaces first, so queue = 1)
        vm.stopPrank();

        // Now add second user and queue
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
        deal(address(asset), charlie, 1000);
        vm.startPrank(charlie);
        asset.approve(address(vault), 1000);
        vault.deposit(1000, charlie);
        uint256 charlieShares = vault.balanceOf(charlie);
        vault.redeem(charlieShares, charlie, charlie);
        vm.stopPrank();

        uint256 queueLength = vault.getRedemptionQueue().getQueueLength();
        assertEq(queueLength, 2, "Queue should have 2 redemptions");

        // Now third user should fail with RedemptionQueueFull
        depositPermissions.allow(address(0x999));
        redeemPermissions.allow(address(0x999));
        deal(address(asset), address(0x999), 1000);
        vm.startPrank(address(0x999));
        asset.approve(address(vault), 1000);
        vault.deposit(1000, address(0x999));
        uint256 shares999 = vault.balanceOf(address(0x999));
        vm.expectRevert(RedemptionQueueFull.selector);
        vault.redeem(shares999, address(0x999), address(0x999));
        vm.stopPrank();
    }

    function testClearQueueResetsLength() public {
        // Setup: Create pool and queue a redemption
        uint256 depositAmount = 100000;
        vm.startPrank(alice);
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        // Tie up capital
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 95000, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Queue one redemption
        vm.startPrank(alice);
        uint256 shares = vault.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 lengthBefore = vault.getRedemptionQueue().getQueueLength();
        assertEq(lengthBefore, 1, "Queue should have 1 redemption");

        // Clear queue
        vm.prank(bullaFactoring.owner());
        vault.getRedemptionQueue().clearQueue();

        uint256 lengthAfter = vault.getRedemptionQueue().getQueueLength();
        assertEq(lengthAfter, 0, "Queue length should be 0 after clearing");

        // Verify max queue size is preserved
        uint256 maxSize = vault.getRedemptionQueue().getMaxQueueSize();
        assertEq(maxSize, 500, "Max queue size should still be 500");
    }
}
