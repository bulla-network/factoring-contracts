// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/RedemptionQueue.sol";
import "../../contracts/interfaces/IRedemptionQueue.sol";

/// @title Tests for compaction after explicit cancellation
/// @notice Verifies that queue compaction works correctly after cancelQueuedRedemption is called
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
    event RedemptionCancelled(address indexed owner, uint256 queueIndex);
    
    function setUp() public {
        vm.prank(owner);
        redemptionQueue = new RedemptionQueue(owner, factoringContract);
    }
    
    /*//////////////////////////////////////////////////////////////
                    COMPACTION AFTER CANCELLATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Test that compaction happens after explicit cancellation via cancelQueuedRedemption
    function test_CompactQueue_AfterExplicitCancellation() public {
        // Setup queue with multiple entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        vm.stopPrank();
        
        // Cancel user1's entry explicitly
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // After explicit cancellation, queue should be compacted
        // User2's entry should now be at index 0
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 entry after cancellation");
        
        IRedemptionQueue.QueuedRedemption memory firstEntry = redemptionQueue.getQueuedRedemption(0);
        assertEq(firstEntry.owner, user2, "User2's entry should be at index 0 after compaction");
        assertEq(firstEntry.shares, SHARES_AMOUNT_2);
        
        // Index 1 should not exist after compaction
        vm.expectRevert(RedemptionQueue.InvalidQueueIndex.selector);
        redemptionQueue.getQueuedRedemption(1);
    }
    
    /// @notice Test cancelling middle entry compacts the queue
    function test_CompactQueue_AfterCancellingMiddleEntry() public {
        // Setup queue with 3 entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        redemptionQueue.queueRedemption(owner, receiver1, SHARES_AMOUNT_3, 0);    // index 2
        vm.stopPrank();
        
        assertEq(redemptionQueue.getQueueLength(), 3, "Should have 3 entries");
        
        // Cancel middle entry (user2) - note: index is 1 before cancellation
        vm.prank(user2);
        redemptionQueue.cancelQueuedRedemption(1);
        
        // After cancellation, activeQueueLength decrements to 2
        assertEq(redemptionQueue.getQueueLength(), 2, "Should have 2 active entries after cancellation");
        
        // Queue is compacted: user1 at 0, owner at 1
        IRedemptionQueue.QueuedRedemption memory entry0 = redemptionQueue.getQueuedRedemption(0);
        IRedemptionQueue.QueuedRedemption memory entry1 = redemptionQueue.getQueuedRedemption(1);
        
        assertEq(entry0.owner, user1, "User1 should be at index 0");
        assertEq(entry0.shares, SHARES_AMOUNT_1);
        assertEq(entry1.owner, owner, "Owner should be at index 1 after compaction");
        assertEq(entry1.shares, SHARES_AMOUNT_3);
        
        // Index 2 should not exist after compaction
        vm.expectRevert(RedemptionQueue.InvalidQueueIndex.selector);
        redemptionQueue.getQueuedRedemption(2);
        
        // FIFO order is maintained - user1 is still first
        IRedemptionQueue.QueuedRedemption memory next = redemptionQueue.getNextRedemption();
        assertEq(next.owner, user1, "Next redemption should be user1");
    }
    
    /// @notice Test compaction after cancelling first entry in queue
    function test_CompactQueue_AfterCancellingFirstEntry() public {
        // Setup queue with entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        vm.stopPrank();
        
        // Cancel first entry
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // After cancellation, queue should be compacted
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 entry after cancellation");
        
        // User2 should now be at index 0
        IRedemptionQueue.QueuedRedemption memory entry = redemptionQueue.getQueuedRedemption(0);
        assertEq(entry.owner, user2, "User2 should be at index 0 after compaction");
        assertEq(entry.shares, SHARES_AMOUNT_2);
    }
    
    /// @notice Test compaction after cancelling last entry in queue
    function test_CompactQueue_AfterCancellingLastEntry() public {
        // Setup queue with entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        vm.stopPrank();
        
        // Cancel last entry
        vm.prank(user2);
        redemptionQueue.cancelQueuedRedemption(1);
        
        // After cancellation, queue is compacted (last entry removed, no shift needed)
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 entry after cancellation");
        
        // User1 should still be at index 0
        IRedemptionQueue.QueuedRedemption memory entry = redemptionQueue.getQueuedRedemption(0);
        assertEq(entry.owner, user1, "User1 should remain at index 0");
        assertEq(entry.shares, SHARES_AMOUNT_1);
    }
    
    /// @notice Test multiple cancellations with compaction
    function test_CompactQueue_AfterMultipleCancellations() public {
        // Setup queue with multiple entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        redemptionQueue.queueRedemption(owner, receiver1, SHARES_AMOUNT_3, 0);    // index 2
        vm.stopPrank();
        
        // Cancel first entry
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // Verify first compaction worked
        assertEq(redemptionQueue.getQueueLength(), 2, "Should have 2 entries");
        
        // Now user2 is at index 0, owner is at index 1
        IRedemptionQueue.QueuedRedemption memory entryAfterFirst = redemptionQueue.getQueuedRedemption(0);
        assertEq(entryAfterFirst.owner, user2, "User2 should be at index 0 after first cancellation");
        
        // Cancel the new first entry (user2)
        vm.prank(user2);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // Verify second compaction worked
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 entry");
        
        // Owner should now be at index 0
        IRedemptionQueue.QueuedRedemption memory finalEntry = redemptionQueue.getQueuedRedemption(0);
        assertEq(finalEntry.owner, owner, "Owner should be at index 0 after second cancellation");
        assertEq(finalEntry.shares, SHARES_AMOUNT_3);
    }
    
    /// @notice Test that cancellation by factoring contract also triggers compaction
    function test_CompactQueue_AfterFactoringContractCancellation() public {
        // Setup queue with entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        
        // Factoring contract cancels user1's entry
        redemptionQueue.cancelQueuedRedemption(0);
        vm.stopPrank();
        
        // After cancellation, queue should be compacted
        assertEq(redemptionQueue.getQueueLength(), 1, "Should have 1 entry after cancellation");
        
        // User2 should now be at index 0
        IRedemptionQueue.QueuedRedemption memory entry = redemptionQueue.getQueuedRedemption(0);
        assertEq(entry.owner, user2, "User2 should be at index 0 after compaction");
    }
    
    /*//////////////////////////////////////////////////////////////
                    MIXED SCENARIOS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Test that multiple different addresses can still queue normally
    function test_QueueRedemption_MultipleAddresses_NormalQueueing() public {
        vm.startPrank(factoringContract);
        
        // Different addresses should get different queue positions
        uint256 user1Index1 = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        uint256 user2Index1 = redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);
        
        assertEq(user1Index1, 0);
        assertEq(user2Index1, 1);
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        vm.stopPrank();
        
        // Verify entries are correct
        IRedemptionQueue.QueuedRedemption memory user1Entry = redemptionQueue.getQueuedRedemption(0);
        IRedemptionQueue.QueuedRedemption memory user2Entry = redemptionQueue.getQueuedRedemption(1);
        
        assertEq(user1Entry.owner, user1);
        assertEq(user1Entry.shares, SHARES_AMOUNT_1);
        
        assertEq(user2Entry.owner, user2);
        assertEq(user2Entry.shares, SHARES_AMOUNT_2);
    }
    
    /// @notice Test queueing after explicit cancellation and compaction
    function test_QueueRedemption_AfterCancellationAndCompaction() public {
        // Setup: Create entries and cancel one
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        vm.stopPrank();
        
        // Cancel user1's entry (triggers compaction)
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // After compaction, user2 is at index 0
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        // Now user1 queues again - should go to index 1
        vm.prank(factoringContract);
        uint256 newIndex = redemptionQueue.queueRedemption(user1, receiver1, 500e18, 0);
        
        assertEq(newIndex, 1, "user1 should get index 1");
        assertEq(redemptionQueue.getQueueLength(), 2, "Should have 2 entries");
        
        // Verify entries
        IRedemptionQueue.QueuedRedemption memory entry0 = redemptionQueue.getQueuedRedemption(0);
        IRedemptionQueue.QueuedRedemption memory entry1 = redemptionQueue.getQueuedRedemption(1);
        
        assertEq(entry0.owner, user2, "User2 should be at index 0");
        assertEq(entry1.owner, user1, "User1 should be at index 1");
        assertEq(entry1.shares, 500e18, "User1 should have new amount");
    }
    
    /// @notice Test that compaction maintains FIFO order
    function test_CompactQueue_MaintainsFIFOOrder() public {
        // Setup queue with entries
        vm.startPrank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);    // index 0
        redemptionQueue.queueRedemption(user2, receiver1, SHARES_AMOUNT_2, 0);    // index 1
        redemptionQueue.queueRedemption(owner, receiver1, SHARES_AMOUNT_3, 0);    // index 2
        vm.stopPrank();
        
        // Cancel middle entry
        vm.prank(user2);
        redemptionQueue.cancelQueuedRedemption(1);
        
        // After compaction, order should be: user1, owner (FIFO maintained)
        IRedemptionQueue.QueuedRedemption memory next = redemptionQueue.getNextRedemption();
        assertEq(next.owner, user1, "First in queue should still be user1");
        
        // Process first and check next
        vm.prank(factoringContract);
        redemptionQueue.removeAmountFromFirstOwner(SHARES_AMOUNT_1);
        
        next = redemptionQueue.getNextRedemption();
        assertEq(next.owner, owner, "Second in queue should be owner");
    }
}
