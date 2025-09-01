// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/RedemptionQueue.sol";
import "../../contracts/interfaces/IRedemptionQueue.sol";

/// @title Tests for redemption queue overwrite behavior
/// @notice These tests should FAIL as the overwrite logic is not yet implemented
contract TestRedemptionQueueOverwrite is Test {
    RedemptionQueue public redemptionQueue;
    
    address public owner = address(0x1);
    address public factoringContract = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public receiver1 = address(0x5);
    address public receiver2 = address(0x6);
    
    // Test constants
    uint256 constant SHARES_AMOUNT_1 = 100e18;
    uint256 constant SHARES_AMOUNT_2 = 200e18;
    uint256 constant SHARES_AMOUNT_3 = 300e18;
    uint256 constant ASSETS_AMOUNT_1 = 50e18;
    uint256 constant ASSETS_AMOUNT_2 = 75e18;
    
    event RedemptionQueued(address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 queueIndex);
    event RedemptionOverwritten(address indexed owner, uint256 oldQueueIndex, uint256 newQueueIndex);
    
    function setUp() public {
        vm.prank(owner);
        redemptionQueue = new RedemptionQueue(owner, factoringContract);
    }
    
    /*//////////////////////////////////////////////////////////////
                    OVERWRITE BEHAVIOR TESTS (SHOULD FAIL)
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Test that when an address queues multiple times, it cancels previous spots and goes to back of queue
    /// @dev This test should now PASS with the new implementation
    function test_QueueRedemption_SameAddress_ShouldCancelAndGoToBack() public {
        // First redemption request
        vm.prank(factoringContract);
        uint256 firstIndex = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        assertEq(firstIndex, 0);
        
        // Verify first entry exists
        IRedemptionQueue.QueuedRedemption memory firstRedemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(firstRedemption.owner, user1);
        assertEq(firstRedemption.shares, SHARES_AMOUNT_1);
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        // Second redemption request from same address - should cancel first and go to back
        vm.prank(factoringContract);
        uint256 secondIndex = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_2, 0);
        
        // After compaction, should get index 0 (queue is compacted automatically)
        assertEq(secondIndex, 0, "Should get index 0 after compaction");
        
        // Queue length should still be 1 (old entry cancelled, new entry added, then compacted)
        assertEq(redemptionQueue.getQueueLength(), 1, "Queue length should remain 1 after cancellation and re-queueing");
        
        // New position should have the updated amount (now at index 0 after compaction)
        IRedemptionQueue.QueuedRedemption memory newRedemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(newRedemption.owner, user1);
        assertEq(newRedemption.shares, SHARES_AMOUNT_2, "Should have new shares amount");
        
        // Total queued for user should be the new amount, not sum
        (uint256 totalShares, uint256 totalAssets) = redemptionQueue.getTotalQueuedForOwner(user1);
        assertEq(totalShares, SHARES_AMOUNT_2, "Total should be new amount, not cumulative");
        assertEq(totalAssets, 0);
    }
    
    /// @notice Test cancel and re-queue behavior with different redemption types (shares vs assets)
    /// @dev This test should now PASS with the new implementation
    function test_QueueRedemption_SameAddress_DifferentTypes_ShouldCancelAndRequeue() public {
        // First: shares redemption
        vm.prank(factoringContract);
        uint256 firstIndex = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        assertEq(firstIndex, 0);
        
        // Second: assets withdrawal from same address - should cancel first and go to back
        vm.prank(factoringContract);
        uint256 secondIndex = redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        // After compaction, should get index 0 (queue is compacted automatically)
        assertEq(secondIndex, 0, "Should get index 0 after compaction");
        
        // Queue length should remain 1 (old cancelled, new added, then compacted)
        assertEq(redemptionQueue.getQueueLength(), 1, "Queue length should remain 1 after cancellation and re-queueing");
        
        // New position should be assets withdrawal, not shares redemption (now at index 0 after compaction)
        IRedemptionQueue.QueuedRedemption memory newRedemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(newRedemption.owner, user1);
        assertEq(newRedemption.shares, 0, "Should be asset withdrawal (shares = 0)");
        assertEq(newRedemption.assets, ASSETS_AMOUNT_1, "Should have assets amount");
    }
    
    /// @notice Test cancel and re-queue behavior with different receivers
    /// @dev This test should now PASS with the new implementation  
    function test_QueueRedemption_SameAddress_DifferentReceiver_ShouldCancelAndRequeue() public {
        // First redemption request
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        // Second redemption request from same address but different receiver - should cancel and go to back
        vm.prank(factoringContract);
        uint256 secondIndex = redemptionQueue.queueRedemption(user1, receiver2, SHARES_AMOUNT_2, 0);
        
        // After compaction, should get index 0 (queue is compacted automatically)
        assertEq(secondIndex, 0, "Should get index 0 after compaction");
        
        // Queue length should remain 1 (old cancelled, new added, then compacted)
        assertEq(redemptionQueue.getQueueLength(), 1, "Queue length should remain 1 after cancellation and re-queueing");
        
        // New position should have updated receiver and shares (now at index 0 after compaction)
        IRedemptionQueue.QueuedRedemption memory newRedemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(newRedemption.owner, user1);
        assertEq(newRedemption.receiver, receiver2, "Should have updated receiver");
        assertEq(newRedemption.shares, SHARES_AMOUNT_2, "Should have updated shares");
    }
    
    /*//////////////////////////////////////////////////////////////
                    CANCEL AND RE-QUEUE WITH HEAD != 0 TESTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Test cancel and re-queue behavior when head pointer is not at 0
    /// @dev This test should now PASS with the new implementation
    function test_QueueRedemption_CancelAndRequeueWithAdvancedHead_ShouldWork() public {
        // Setup: Create multiple queue entries and advance head
        vm.startPrank(factoringContract);
        
        // Add initial entries
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1  
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_3, 0);    // index 1 now, since it overwrites user1's entry at index 0
        
        // Process first entry completely to advance head to index 1
        redemptionQueue.removeAmountFromFirstOwner(SHARES_AMOUNT_2);
        
        vm.stopPrank();
        
        // Verify head is now at index 1
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.getNextRedemption();
        assertEq(nextRedemption.owner, user1, "Head should be at user1's entry");
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 active entry");
        
        // Now user1 queues again - should cancel their existing entry at index 2 and go to back
        vm.prank(factoringContract);
        uint256 newIndex = redemptionQueue.queueRedemption(user1, receiver1, 400e18, 0);
        
        // After compaction, should get index 0 (user1's new entry at index 0, overwriting old entry)
        assertEq(newIndex, 0, "Should get index 0 after compaction");
        
        // Queue length should remain 1 (one cancelled, one added, then compacted)
        assertEq(redemptionQueue.getQueueLength(), 1, "Queue length should remain 1 after cancellation and re-queueing");
        
        // New entry at index 1 should have updated amount
        IRedemptionQueue.QueuedRedemption memory newEntry = redemptionQueue.getQueuedRedemption(0);
        assertEq(newEntry.owner, user1);
        assertEq(newEntry.shares, 400e18, "Should have updated shares amount");
        
        // Head should still be at user2's entry
        IRedemptionQueue.QueuedRedemption memory stillNextRedemption = redemptionQueue.getNextRedemption();
        assertEq(stillNextRedemption.owner, user1, "Head should still be at user1's entry");
    }
    
    /// @notice Test cancel and re-queue when entries are already cancelled and head is advanced
    /// @dev This test should now PASS with the new implementation
    function test_QueueRedemption_CancelledEntriesWithAdvancedHead() public {
        vm.startPrank(factoringContract);
        
        // Setup queue
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        
        vm.stopPrank();
        
        // Manually cancel user1's entry (index 0) to advance head
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // Verify head advanced to user2's entry
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.getNextRedemption();
        assertEq(nextRedemption.owner, user2, "Head should be at user2's entry");
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 active entry");
        
        // Now user1 queues again - should go to back of queue (no existing entries to cancel)
        vm.prank(factoringContract);
        uint256 newIndex = redemptionQueue.queueRedemption(user1, receiver1, 500e18, 0);
        
        // After compaction, should get index 1 (user2 at index 0, user1's new entry at index 1)
        assertEq(newIndex, 1, "Should get index 1 after compaction");
        
        // Queue length should be 2 (user2 + new user1 entry)
        assertEq(redemptionQueue.getQueueLength(), 2, "Should have 2 entries");
        
        // User2's entry should be at index 0 (after compaction)
        IRedemptionQueue.QueuedRedemption memory user2Entry = redemptionQueue.getQueuedRedemption(0);
        assertEq(user2Entry.owner, user2, "User2's entry should still be active");
        
        // New entry should be at index 1
        IRedemptionQueue.QueuedRedemption memory newEntry = redemptionQueue.getQueuedRedemption(1);
        assertEq(newEntry.owner, user1);
        assertEq(newEntry.shares, 500e18, "Should have new shares amount");
        
        // Total queued for user1 should only be the new amount
        (uint256 totalShares,) = redemptionQueue.getTotalQueuedForOwner(user1);
        assertEq(totalShares, 500e18, "Should only have new amount, not cumulative");
    }
    
    /*//////////////////////////////////////////////////////////////
                    MIXED SCENARIOS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Test that multiple different addresses can still queue normally while cancel and re-queue works
    /// @dev This test should now PASS with the new implementation
    function test_QueueRedemption_MultipleAddresses_OnlyCancelsSameAddress() public {
        vm.startPrank(factoringContract);
        
        // Different addresses should get different queue positions
        uint256 user1Index1 = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        uint256 user2Index1 = redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);
        
        assertEq(user1Index1, 0);
        assertEq(user2Index1, 1);
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        // Same address queuing again should cancel previous and go to back
        uint256 user1Index2 = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_3, 0);
        
        // After compaction, user1 should get index 1 (user2 still at index 0, user1's new entry at index 1)
        assertEq(user1Index2, 1, "user1 should get index 1 after compaction");
        
        // Queue should still have 2 entries (one cancelled, one added, then compacted)
        assertEq(redemptionQueue.getQueueLength(), 2, "Should still have 2 entries");
        
        // Different address queuing should cancel their own and go to back
        uint256 user2Index2 = redemptionQueue.queueRedemption(user2, receiver1, 0, ASSETS_AMOUNT_1);
        
        // After compaction, user2 should get index 1 (user1 at index 0, user2's new entry at index 1)
        assertEq(user2Index2, 1, "user2 should get index 1 after compaction");
        
        // Queue should still have 2 entries
        assertEq(redemptionQueue.getQueueLength(), 2, "Should still have 2 entries after user2 re-queue");
        
        vm.stopPrank();
        
        // New entries should be in compacted queue
        IRedemptionQueue.QueuedRedemption memory user1Final = redemptionQueue.getQueuedRedemption(0);
        IRedemptionQueue.QueuedRedemption memory user2Final = redemptionQueue.getQueuedRedemption(1);
        
        assertEq(user1Final.owner, user1);
        assertEq(user1Final.shares, SHARES_AMOUNT_3, "user1 should have final shares amount");
        
        assertEq(user2Final.owner, user2);
        assertEq(user2Final.assets, ASSETS_AMOUNT_1, "user2 should have final assets amount");
        assertEq(user2Final.shares, 0, "user2 should have assets withdrawal");
    }
}
