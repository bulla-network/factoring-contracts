// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/RedemptionQueue.sol";
import "../../contracts/interfaces/IRedemptionQueue.sol";

contract RedemptionQueueTest is Test {
    RedemptionQueue public redemptionQueue;
    
    address public owner = address(0x1);
    address public factoringContract = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public receiver1 = address(0x5);
    address public receiver2 = address(0x6);
    address public unauthorized = address(0x7);
    
    // Test constants
    uint256 constant SHARES_AMOUNT_1 = 100e18;
    uint256 constant SHARES_AMOUNT_2 = 200e18;
    uint256 constant ASSETS_AMOUNT_1 = 50e18;
    uint256 constant ASSETS_AMOUNT_2 = 75e18;
    
    event RedemptionQueued(address indexed owner, address indexed receiver, uint256 shares, uint256 assets, uint256 queueIndex);
    event RedemptionCancelled(address indexed owner, uint256 queueIndex);
    event RedemptionProcessed(address indexed owner, address indexed receiver, uint256 sharesProcessed, uint256 assetsProcessed, uint256 queueIndex);
    
    function setUp() public {
        vm.prank(owner);
        redemptionQueue = new RedemptionQueue(owner, factoringContract);
    }
    
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Constructor_SetsOwnerCorrectly() public view {
        assertEq(redemptionQueue.owner(), owner);
    }
    
    function test_Constructor_SetsFactoringContractCorrectly() public view {
        assertEq(redemptionQueue.factoringContract(), factoringContract);
    }
    
    function test_Constructor_InitializesEmptyQueue() public view {
        assertTrue(redemptionQueue.isQueueEmpty());
        assertEq(redemptionQueue.getQueueLength(), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetFactoringContract_OnlyOwner() public {
        address newFactoringContract = address(0x999);
        
        vm.prank(owner);
        redemptionQueue.setFactoringContract(newFactoringContract);
        
        assertEq(redemptionQueue.factoringContract(), newFactoringContract);
    }
    
    function test_SetFactoringContract_RevertIfNotOwner() public {
        address newFactoringContract = address(0x999);
        
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        redemptionQueue.setFactoringContract(newFactoringContract);
    }
    
    function test_QueueRedemption_OnlyFactoringContract() public {
        vm.prank(factoringContract);
        uint256 queueIndex = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        assertEq(queueIndex, 0);
        assertFalse(redemptionQueue.isQueueEmpty());
    }
    
    function test_QueueRedemption_RevertIfNotFactoringContract() public {
        vm.prank(unauthorized);
        vm.expectRevert(RedemptionQueue.OnlyFactoringContract.selector);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
    }
    
    function test_RemoveAmountFromFirstOwner_OnlyFactoringContract() public {
        // Setup queue first
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.removeAmountFromFirstOwner(50e18);
        
        // Should return the remaining partial redemption
        assertEq(nextRedemption.owner, user1);
        assertEq(nextRedemption.shares, SHARES_AMOUNT_1 - 50e18);
    }
    
    function test_RemoveAmountFromFirstOwner_RevertIfNotFactoringContract() public {
        // Setup queue first
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(unauthorized);
        vm.expectRevert(RedemptionQueue.OnlyFactoringContract.selector);
        redemptionQueue.removeAmountFromFirstOwner(50e18);
    }
    
    function test_ClearQueue_OnlyOwner() public {
        // Setup queue first
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(owner);
        redemptionQueue.clearQueue();
        
        assertTrue(redemptionQueue.isQueueEmpty());
    }
    
    function test_ClearQueue_RevertIfNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        redemptionQueue.clearQueue();
    }
    
    /*//////////////////////////////////////////////////////////////
                            QUEUE REDEMPTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_QueueRedemption_ShareBased_Success() public {
        vm.expectEmit(true, true, false, true);
        emit RedemptionQueued(user1, receiver1, SHARES_AMOUNT_1, 0, 0);
        
        vm.prank(factoringContract);
        uint256 queueIndex = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        assertEq(queueIndex, 0);
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(redemption.owner, user1);
        assertEq(redemption.receiver, receiver1);
        assertEq(redemption.shares, SHARES_AMOUNT_1);
        assertEq(redemption.assets, 0);
    }
    
    function test_QueueRedemption_AssetBased_Success() public {
        vm.expectEmit(true, true, false, true);
        emit RedemptionQueued(user1, receiver1, 0, ASSETS_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        uint256 queueIndex = redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        assertEq(queueIndex, 0);
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(redemption.owner, user1);
        assertEq(redemption.receiver, receiver1);
        assertEq(redemption.shares, 0);
        assertEq(redemption.assets, ASSETS_AMOUNT_1);
    }
    
    function test_QueueRedemption_MultipleRedemptions() public {
        vm.prank(factoringContract);
        uint256 index1 = redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        uint256 index2 = redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1);
        
        assertEq(index1, 0);
        assertEq(index2, 1);
        assertEq(redemptionQueue.getQueueLength(), 2);
    }
    
    function test_QueueRedemption_RevertIfZeroOwner() public {
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.InvalidOwner.selector);
        redemptionQueue.queueRedemption(address(0), receiver1, SHARES_AMOUNT_1, 0);
    }
    
    function test_QueueRedemption_RevertIfZeroReceiver() public {
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.InvalidReceiver.selector);
        redemptionQueue.queueRedemption(user1, address(0), SHARES_AMOUNT_1, 0);
    }
    
    function test_QueueRedemption_RevertIfBothSharesAndAssets() public {
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.InvalidRedemptionType.selector);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, ASSETS_AMOUNT_1);
    }
    
    function test_QueueRedemption_RevertIfNeitherSharesNorAssets() public {
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.InvalidRedemptionType.selector);
        redemptionQueue.queueRedemption(user1, receiver1, 0, 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                            CANCEL REDEMPTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CancelQueuedRedemption_ByOwner() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.expectEmit(true, false, false, true);
        emit RedemptionCancelled(user1, 0);
        
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        assertTrue(redemptionQueue.isQueueEmpty());
    }
    
    function test_CancelQueuedRedemption_ByFactoringContract() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.expectEmit(true, false, false, true);
        emit RedemptionCancelled(user1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.cancelQueuedRedemption(0);
        
        assertTrue(redemptionQueue.isQueueEmpty());
    }
    
    function test_CancelQueuedRedemption_RevertIfUnauthorized() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(unauthorized);
        vm.expectRevert(RedemptionQueue.NotAuthorized.selector);
        redemptionQueue.cancelQueuedRedemption(0);
    }
    
    function test_CancelQueuedRedemption_RevertIfInvalidIndex() public {
        vm.prank(user1);
        vm.expectRevert(RedemptionQueue.InvalidQueueIndex.selector);
        redemptionQueue.cancelQueuedRedemption(0);
    }
    
    function test_CancelQueuedRedemption_MiddleItem_PreservesOrder() public {
        // Setup queue with multiple items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, SHARES_AMOUNT_2, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 150e18, 0);
        
        // Cancel middle item
        vm.prank(user2);
        redemptionQueue.cancelQueuedRedemption(1);
        
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        // Verify first item is still user1's first redemption
        IRedemptionQueue.QueuedRedemption memory firstRedemption = redemptionQueue.getNextRedemption();
        assertEq(firstRedemption.owner, user1);
        assertEq(firstRedemption.shares, SHARES_AMOUNT_1);
        
        // Verify cancelled item is marked as cancelled
        IRedemptionQueue.QueuedRedemption memory cancelledRedemption = redemptionQueue.getQueuedRedemption(1);
        assertEq(cancelledRedemption.owner, address(0));

        // Verify cancelled item is marked as cancelled
        IRedemptionQueue.QueuedRedemption memory thirdRedemption = redemptionQueue.getQueuedRedemption(2);
        assertEq(thirdRedemption.owner, user1);
        assertEq(thirdRedemption.shares, 150e18);
    }
    
    function test_CancelQueuedRedemption_HeadItem_AdvancesHead() public {
        // Setup queue with multiple items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, SHARES_AMOUNT_2, 0);
        
        // Cancel first (head) item
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        // Verify second item is now the head
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.getNextRedemption();
        assertEq(nextRedemption.owner, user2);
        assertEq(nextRedemption.shares, SHARES_AMOUNT_2);
    }
    
    /*//////////////////////////////////////////////////////////////
                            REMOVE AMOUNT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_RemoveAmountFromFirstOwner_PartialShares() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        uint256 removeAmount = SHARES_AMOUNT_1 - 10e18;
        
        vm.expectEmit(true, true, false, true);
        emit RedemptionProcessed(user1, receiver1, removeAmount, 0, 0);
        
        vm.prank(factoringContract);
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.removeAmountFromFirstOwner(removeAmount);
        
        // Check remaining redemption is still the first item
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        assertEq(redemption.shares, SHARES_AMOUNT_1 - removeAmount);
        
        // Next redemption should be the same updated redemption
        assertEq(nextRedemption.owner, user1);
        assertEq(nextRedemption.shares, SHARES_AMOUNT_1 - removeAmount);
    }
    
    function test_RemoveAmountFromFirstOwner_CompleteShares() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.expectEmit(true, true, false, true);
        emit RedemptionProcessed(user1, receiver1, SHARES_AMOUNT_1, 0, 0);
        
        vm.prank(factoringContract);
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.removeAmountFromFirstOwner(SHARES_AMOUNT_1);
        
        // Queue should be empty
        assertTrue(redemptionQueue.isQueueEmpty());
        
        // Next redemption should be empty
        assertEq(nextRedemption.owner, address(0));
    }
    
    function test_RemoveAmountFromFirstOwner_PartialAssets() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        uint256 removeAmount = ASSETS_AMOUNT_1 - 10e18;
        
        vm.expectEmit(true, true, false, true);
        emit RedemptionProcessed(user1, receiver1, 0, removeAmount, 0);
        
        vm.prank(factoringContract);
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.removeAmountFromFirstOwner(removeAmount);
        
        // Check remaining redemption
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        assertEq(redemption.assets, ASSETS_AMOUNT_1 - removeAmount);
        
        // Next redemption should be the same updated redemption
        assertEq(nextRedemption.owner, user1);
        assertEq(nextRedemption.assets, ASSETS_AMOUNT_1 - removeAmount);
    }
    
    function test_RemoveAmountFromFirstOwner_CompleteAssets() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        vm.expectEmit(true, true, false, true);
        emit RedemptionProcessed(user1, receiver1, 0, ASSETS_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.removeAmountFromFirstOwner(ASSETS_AMOUNT_1);
        
        // Queue should be empty
        assertTrue(redemptionQueue.isQueueEmpty());
        
        // Next redemption should be empty
        assertEq(nextRedemption.owner, address(0));
    }
    
    function test_RemoveAmountFromFirstOwner_WithMultipleInQueue() public {
        // Setup queue with multiple items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, SHARES_AMOUNT_2, 0);
        
        // Remove complete first redemption
        vm.prank(factoringContract);
        IRedemptionQueue.QueuedRedemption memory nextRedemption = redemptionQueue.removeAmountFromFirstOwner(SHARES_AMOUNT_1);
        
        // Queue should have 1 item left
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        // Next redemption should be user2's
        assertEq(nextRedemption.owner, user2);
        assertEq(nextRedemption.shares, SHARES_AMOUNT_2);
    }
    
    function test_RemoveAmountFromFirstOwner_RevertIfEmptyQueue() public {
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.QueueEmpty.selector);
        redemptionQueue.removeAmountFromFirstOwner(100e18);
    }
    
    function test_RemoveAmountFromFirstOwner_RevertIfAmountExceedsShares() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.AmountExceedsQueuedShares.selector);
        redemptionQueue.removeAmountFromFirstOwner(SHARES_AMOUNT_1 + 1);
    }
    
    function test_RemoveAmountFromFirstOwner_RevertIfAmountExceedsAssets() public {
        // Setup queue
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        vm.prank(factoringContract);
        vm.expectRevert(RedemptionQueue.AmountExceedsQueuedAssets.selector);
        redemptionQueue.removeAmountFromFirstOwner(ASSETS_AMOUNT_1 + 1);
    }
    
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_IsQueueEmpty_True() public view {
        assertTrue(redemptionQueue.isQueueEmpty());
    }
    
    function test_IsQueueEmpty_False() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        assertFalse(redemptionQueue.isQueueEmpty());
    }
    
    function test_GetQueueLength() public {
        assertEq(redemptionQueue.getQueueLength(), 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1);
        assertEq(redemptionQueue.getQueueLength(), 2);
    }
    
    function test_GetQueueLength_WithCancelledItems() public {
        // Add three items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_2, 0);
        
        assertEq(redemptionQueue.getQueueLength(), 3);
        
        // Cancel middle item
        vm.prank(user2);
        redemptionQueue.cancelQueuedRedemption(1);
        
        // Length should still be 2 (first and third items are active)
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        // Cancel first item - this should advance head
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // Length should be 1 (only third item is active)
        assertEq(redemptionQueue.getQueueLength(), 1);
    }
    
    function test_GetQueuedRedemption() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(redemption.owner, user1);
        assertEq(redemption.receiver, receiver1);
        assertEq(redemption.shares, SHARES_AMOUNT_1);
        assertEq(redemption.assets, 0);
    }
    
    function test_GetQueuedRedemption_RevertIfInvalidIndex() public {
        vm.expectRevert(RedemptionQueue.InvalidQueueIndex.selector);
        redemptionQueue.getQueuedRedemption(0);
    }
    
    function test_GetQueuedRedemptionsForOwner_EmptyQueue() public view {
        uint256[] memory indexes = redemptionQueue.getQueuedRedemptionsForOwner(user1);
        assertEq(indexes.length, 0);
    }
    
    function test_GetQueuedRedemptionsForOwner_NoMatches() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        uint256[] memory indexes = redemptionQueue.getQueuedRedemptionsForOwner(user2);
        assertEq(indexes.length, 0);
    }
    
    function test_GetQueuedRedemptionsForOwner_SingleMatch() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        uint256[] memory indexes = redemptionQueue.getQueuedRedemptionsForOwner(user1);
        assertEq(indexes.length, 1);
        assertEq(indexes[0], 0);
    }
    
    function test_GetQueuedRedemptionsForOwner_MultipleMatches() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_2, 0);
        
        uint256[] memory indexes = redemptionQueue.getQueuedRedemptionsForOwner(user1);
        assertEq(indexes.length, 2);
        assertEq(indexes[0], 0);
        assertEq(indexes[1], 2);
    }
    
    function test_GetQueuedRedemptionsForOwner_SkipsCancelledItems() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_2, 0);
        
        // Cancel middle item
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(1);
        
        uint256[] memory indexes = redemptionQueue.getQueuedRedemptionsForOwner(user1);
        assertEq(indexes.length, 2);
        assertEq(indexes[0], 0);
        assertEq(indexes[1], 2);
    }
    
    function test_GetTotalQueuedForOwner_EmptyQueue() public view {
        (uint256 totalShares, uint256 totalAssets) = redemptionQueue.getTotalQueuedForOwner(user1);
        assertEq(totalShares, 0);
        assertEq(totalAssets, 0);
    }
    
    function test_GetTotalQueuedForOwner_NoMatches() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        (uint256 totalShares, uint256 totalAssets) = redemptionQueue.getTotalQueuedForOwner(user2);
        assertEq(totalShares, 0);
        assertEq(totalAssets, 0);
    }
    
    function test_GetTotalQueuedForOwner_MixedRedemptions() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 0, ASSETS_AMOUNT_1);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_2, 0);
        
        (uint256 totalShares, uint256 totalAssets) = redemptionQueue.getTotalQueuedForOwner(user1);
        assertEq(totalShares, SHARES_AMOUNT_1 + SHARES_AMOUNT_2);
        assertEq(totalAssets, ASSETS_AMOUNT_1);
    }
    
    function test_GetNextRedemption_EmptyQueue() public view {
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        assertEq(redemption.owner, address(0));
        assertEq(redemption.receiver, address(0));
        assertEq(redemption.shares, 0);
        assertEq(redemption.assets, 0);
    }
    
    function test_GetNextRedemption_WithItems() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        assertEq(redemption.owner, user1);
        assertEq(redemption.receiver, receiver1);
        assertEq(redemption.shares, SHARES_AMOUNT_1);
        assertEq(redemption.assets, 0);
    }
    
    function test_GetQueueStats_EmptyQueue() public view {
        (uint256 queueLength, uint256 totalShares, uint256 totalAssets) = redemptionQueue.getQueueStats();
        assertEq(queueLength, 0);
        assertEq(totalShares, 0);
        assertEq(totalAssets, 0);
    }
    
    function test_GetQueueStats_WithItems() public {
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_2, 0);
        
        (uint256 queueLength, uint256 totalShares, uint256 totalAssets) = redemptionQueue.getQueueStats();
        assertEq(queueLength, 3);
        assertEq(totalShares, SHARES_AMOUNT_1 + SHARES_AMOUNT_2);
        assertEq(totalAssets, ASSETS_AMOUNT_1);
    }
    
    /*//////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ClearQueue_WithItems() public {
        // Setup queue with multiple items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1);
        
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        vm.prank(owner);
        redemptionQueue.clearQueue();
        
        assertTrue(redemptionQueue.isQueueEmpty());
        assertEq(redemptionQueue.getQueueLength(), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                            COMPACT QUEUE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_CompactQueue_OnlyOwner() public {
        // Setup queue with items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, SHARES_AMOUNT_2, 0);
        
        // Process first item to advance head
        vm.prank(factoringContract);
        redemptionQueue.removeAmountFromFirstOwner(SHARES_AMOUNT_1);
        
        vm.prank(owner);
        redemptionQueue.compactQueue();
        
        // Queue should still have 1 item and be functional
        assertEq(redemptionQueue.getQueueLength(), 1);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        assertEq(redemption.owner, user2);
    }
    
    function test_CompactQueue_WithCancellations() public {
        // Setup queue with multiple items
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, SHARES_AMOUNT_1, 0); // index 0
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, SHARES_AMOUNT_2, 0); // index 1
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, 150e18, 0); // index 2
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user2, receiver2, 0, ASSETS_AMOUNT_1); // index 3
        
        // Cancel first item (head) - this should advance head to index 1
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(0);
        
        // Cancel item at index 2
        vm.prank(user1);
        redemptionQueue.cancelQueuedRedemption(2);
        
        // At this point: head=1, active items at indexes 1 and 3
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        // Verify current head is user2's first redemption
        IRedemptionQueue.QueuedRedemption memory currentHead = redemptionQueue.getNextRedemption();
        assertEq(currentHead.owner, user2);
        assertEq(currentHead.shares, SHARES_AMOUNT_2);
        
        // Compact the queue
        vm.prank(owner);
        redemptionQueue.compactQueue();
        
        // After compaction, should still have 2 active items but head should be reset to 0
        assertEq(redemptionQueue.getQueueLength(), 2);
        
        // Verify first item after compaction is user2's first redemption (shares)
        IRedemptionQueue.QueuedRedemption memory firstAfterCompact = redemptionQueue.getNextRedemption();
        assertEq(firstAfterCompact.owner, user2);
        assertEq(firstAfterCompact.shares, SHARES_AMOUNT_2);
        assertEq(firstAfterCompact.assets, 0);
        
        // Verify second item is user2's second redemption (assets)
        IRedemptionQueue.QueuedRedemption memory secondAfterCompact = redemptionQueue.getQueuedRedemption(1);
        assertEq(secondAfterCompact.owner, user2);
        assertEq(secondAfterCompact.shares, 0);
        assertEq(secondAfterCompact.assets, ASSETS_AMOUNT_1);
        
        // Verify cancelled items are not accessible anymore (should revert for index 2+)
        vm.expectRevert(RedemptionQueue.InvalidQueueIndex.selector);
        redemptionQueue.getQueuedRedemption(2);
    }
    
    function test_CompactQueue_RevertIfNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        redemptionQueue.compactQueue();
    }
    
    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_QueueRedemption_SharesAmount(uint256 shares) public {
        vm.assume(shares > 0);
        vm.assume(shares < type(uint256).max);
        
        vm.prank(factoringContract);
        uint256 queueIndex = redemptionQueue.queueRedemption(user1, receiver1, shares, 0);
        
        assertEq(queueIndex, 0);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(redemption.shares, shares);
    }
    
    function testFuzz_QueueRedemption_AssetsAmount(uint256 assets) public {
        vm.assume(assets > 0);
        vm.assume(assets < type(uint256).max);
        
        vm.prank(factoringContract);
        uint256 queueIndex = redemptionQueue.queueRedemption(user1, receiver1, 0, assets);
        
        assertEq(queueIndex, 0);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getQueuedRedemption(0);
        assertEq(redemption.assets, assets);
    }
    
    function testFuzz_RemoveAmountFromFirstOwner_PartialShares(uint256 totalShares, uint256 removeAmount) public {
        vm.assume(totalShares > 1);
        vm.assume(removeAmount > 0);
        vm.assume(removeAmount < totalShares);
        
        vm.prank(factoringContract);
        redemptionQueue.queueRedemption(user1, receiver1, totalShares, 0);
        
        vm.prank(factoringContract);
        redemptionQueue.removeAmountFromFirstOwner(removeAmount);
        
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        assertEq(redemption.shares, totalShares - removeAmount);
    }
} 