// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IRedemptionQueue} from "../../contracts/interfaces/IRedemptionQueue.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/BullaClaim.sol";
import {EIP712Helper} from "./utils/EIP712Helper.sol";

/**
 * @title TestRedemptionQueueIntegration
 * @notice Tests redemption queue functionality integrated with BullaFactoring
 * @dev Tests automatic queue processing, FIFO ordering, and integration with other contract functions
 */
contract TestRedemptionQueueIntegration is CommonSetup {
    EIP712Helper public sigHelper;
    // Additional test users
    address david = address(0x4);
    address eve = address(0x5);
    
    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Grant permissions to charlie for deposits/redemptions
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
        factoringPermissions.allow(alice);
        factoringPermissions.allow(charlie);

        // Set up permitCreateClaim for Bob to create loans via BullaFrendLend
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: bob,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: bobPK,
                user: bob,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });

        // Setup additional test users with asset
        deal(address(asset), david, 10000000);
        deal(address(asset), eve, 10000000);
        
        // Grant permissions for additional users
        depositPermissions.allow(david);
        depositPermissions.allow(eve);
        redeemPermissions.allow(david);
        redeemPermissions.allow(eve);
        factoringPermissions.allow(david);
        factoringPermissions.allow(eve);
        bullaApprovalRegistry.setAuthorizedContract(david, true);
        bullaApprovalRegistry.setAuthorizedContract(eve, true);
        
        // Approve asset for all test users
        vm.prank(david);
        asset.approve(address(bullaFactoring), type(uint256).max);
        
        vm.prank(eve);
        asset.approve(address(bullaFactoring), type(uint256).max);
        
        // Additional approvals for bullaClaim contract for payments
        vm.prank(alice);
        asset.approve(address(bullaClaim), type(uint256).max);
        
        vm.prank(bob);
        asset.approve(address(bullaClaim), type(uint256).max);
        
        vm.prank(charlie);
        asset.approve(address(bullaClaim), type(uint256).max);
        
        vm.prank(david);
        asset.approve(address(bullaClaim), type(uint256).max);
        
        vm.prank(eve);
        asset.approve(address(bullaClaim), type(uint256).max);
    }

    // ============================================
    // 1. Basic Queue Functionality Tests
    // ============================================

    function testRedeemAndOrQueue_FullRedemptionWhenSufficientLiquidity() public {
        uint256 depositAmount = 1000000;
        uint256 redeemShares = 500000;
        
        // Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Alice attempts to redeem - should fully redeem
        vm.prank(alice);
        (uint256 redeemedAssets, uint256 queuedShares) = bullaFactoring.redeemAndOrQueue(redeemShares, alice, alice);
        
        assertEq(redeemedAssets, redeemShares, "Should redeem full amount");
        assertEq(queuedShares, 0, "Should not queue any shares");
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
    }

    function testRedeemAndOrQueue_PartialRedemptionWithQueuing() public {
        uint256 depositAmount = 1000000;
        uint256 redeemShares = 800000;
        uint256 invoiceAmount = 600000;
        
        // Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Fund an invoice to reduce liquidity
        vm.prank(alice);
        uint256 invoiceId = createClaim(alice, bob, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0, 0);
        
        vm.prank(alice);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(alice);
        bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        // Alice attempts to redeem more than available - should partially redeem and queue
        vm.prank(alice);
        (uint256 redeemedAssets, uint256 queuedShares) = bullaFactoring.redeemAndOrQueue(redeemShares, alice, alice);
        
        assertTrue(redeemedAssets > 0, "Should redeem some amount");
        assertTrue(queuedShares > 0, "Should queue remaining shares");
        assertEq(redeemedAssets + queuedShares, redeemShares, "Total should equal requested");
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should not be empty");
    }

    function testRedeemAndOrQueue_ZeroRedemptionWithFullQueuing() public {
        uint256 depositAmount = 1000000;
        uint256 redeemShares = 500000;
        
        // Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Fund an invoice that uses all liquidity
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, depositAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        
        // Alice attempts to redeem - should queue all shares
        vm.prank(alice);
        (uint256 redeemedAssets, uint256 queuedShares) = bullaFactoring.redeemAndOrQueue(redeemShares, alice, alice);
        
        assertEq(redeemedAssets, 0, "Should redeem nothing");
        assertEq(queuedShares, redeemShares, "Should queue all shares");
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should not be empty");
    }

    function testWithdrawAndOrQueue_FullWithdrawalWhenSufficientLiquidity() public {
        uint256 depositAmount = 1000000;
        uint256 withdrawAssets = 500000;
        
        // Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Alice attempts to withdraw - should fully withdraw
        vm.prank(alice);
        (uint256 redeemedShares, uint256 queuedAssets) = bullaFactoring.withdrawAndOrQueue(withdrawAssets, alice, alice);
        
        assertEq(redeemedShares, withdrawAssets, "Should redeem equivalent shares");
        assertEq(queuedAssets, 0, "Should not queue any assets");
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
    }

    function testWithdrawAndOrQueue_PartialWithdrawalWithQueuing() public {
        uint256 depositAmount = 1000000;
        uint256 withdrawAssets = 800000;
        uint256 invoiceAmount = 600000;
        
        // Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Fund an invoice to reduce liquidity
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        // Alice attempts to withdraw more than available - should partially withdraw and queue
        vm.prank(alice);
        (uint256 redeemedShares, uint256 queuedAssets) = bullaFactoring.withdrawAndOrQueue(withdrawAssets, alice, alice);
        
        assertTrue(redeemedShares > 0, "Should redeem some shares");
        assertTrue(queuedAssets > 0, "Should queue remaining assets");
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should not be empty");
    }

    function testWithdrawAndOrQueue_ZeroWithdrawalWithFullQueuing() public {
        uint256 depositAmount = 1000000;
        uint256 withdrawAssets = 500000;
        
        // Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Fund an invoice that uses all liquidity
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, depositAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        
        // Alice attempts to withdraw - should queue all assets
        vm.prank(alice);
        (uint256 redeemedShares, uint256 queuedAssets) = bullaFactoring.withdrawAndOrQueue(withdrawAssets, alice, alice);
        
        assertEq(redeemedShares, 0, "Should redeem no shares");
        assertEq(queuedAssets, withdrawAssets, "Should queue all assets");
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should not be empty");
    }

    // ============================================
    // 2. Automatic Queue Processing Tests
    // ============================================

    function testQueueProcessing_TriggeredByDeposit() public {
        uint256 initialDeposit = 1000000;
        uint256 queueAmount = 300000;
        uint256 newDeposit = 500000;
        
        // Setup: Alice deposits, queues redemption, then Bob deposits to trigger processing
        vm.prank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        
        // Fund invoice to reduce liquidity
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 9000, 0, 0);
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 9000, address(0));
        
        // Alice queues redemption
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        
        // Bob deposits - should trigger queue processing
        vm.prank(bob);
        bullaFactoring.deposit(newDeposit, bob);
        
        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should receive processed redemption");
    }

    function testQueueProcessing_TriggeredByReconcileActivePaidInvoices() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 300000;
        
        // Setup with queued redemption
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, eve, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 9000, 0, 0);
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 9000, address(0));
        
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        
        // Pay the invoice
        vm.prank(eve);
        bullaClaim.payClaim(invoiceId, 800000);
        
        // Reconcile - should trigger queue processing
        bullaFactoring.reconcileActivePaidInvoices();
        
        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should receive processed redemption");
    }

    function testQueueProcessing_TriggeredByRedeem() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 200000;
        uint256 directRedeemAmount = 100000;
        uint256 invoiceAmount = 1500000;
        
        // Setup: Alice and Bob deposit, Alice queues, Bob redeems to trigger processing
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        // Fund invoice to reduce liquidity
        vm.prank(charlie);
        uint256 invoiceId = createClaim(charlie, eve, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0, 0);
        vm.prank(charlie);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(charlie);
        bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        // Alice queues redemption
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(depositAmount, alice, alice);
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);

        // Pay the invoice to add liquidity
        vm.prank(eve);
        asset.approve(address(bullaClaim), invoiceAmount);
        vm.prank(eve);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        
        // Bob redeems - should trigger queue processing
        vm.prank(bob);
        bullaFactoring.redeem(directRedeemAmount, bob, bob);
        
        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Queue processing should be triggered");
    }

    function testQueueProcessing_TriggeredByOfferLoan() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 500000;
        
        // Setup with queued redemption
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        // Create, fund, and pay an invoice to add liquidity for queue processing
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, eve, depositAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        // Pay the invoice to add liquidity
        vm.prank(eve);
        asset.approve(address(bullaClaim), depositAmount);
        vm.prank(eve);
        bullaClaim.payClaim(invoiceId, depositAmount);
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        
        // Underwriter offers loan - should trigger queue processing
        vm.prank(underwriter);
        bullaFactoring.offerLoan(bob, 1000, 100, 200000, 30 days, 12, "Test loan");
        
        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        
        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Queue processing should be triggered");
    }

    // ============================================
    // 3. FIFO Queue Order Tests
    // ============================================

    function testFIFOQueueOrder_MultipleUsersQueueInOrder() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount =    600000;
        
        // All users deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Fund large invoice to eliminate liquidity
        vm.prank(david);
        uint256 invoiceId = createClaim(david, eve, 2500000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0);
        vm.prank(david);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(david);
        bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        
        // Users queue redemptions in order: Alice, Bob, Charlie
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        vm.prank(bob);
        bullaFactoring.redeemAndOrQueue(queueAmount, bob, bob);
        
        vm.prank(charlie);
        bullaFactoring.redeemAndOrQueue(queueAmount, charlie, charlie);
        
        // Read balances before triggering queue processing
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 charlieBalanceBefore = asset.balanceOf(charlie);
        
        // Add limited liquidity through deposits - enough for only Alice's redemption (600k + buffer)
        vm.prank(david);
        bullaFactoring.deposit(650000, david); // Only enough for Alice's redemption + some for Bob
        
        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        uint256 charlieBalanceAfter = asset.balanceOf(charlie);
        
        // Alice should be processed first (FIFO), Bob may be partially processed, Charlie should not be processed
        assertTrue(aliceBalanceAfter > aliceBalanceBefore, "Alice should be processed first (FIFO)");
        
        // Bob might get partially processed if there's enough liquidity left after Alice
        uint256 aliceIncrease = aliceBalanceAfter - aliceBalanceBefore;
        uint256 bobIncrease = bobBalanceAfter - bobBalanceBefore;
        uint256 charlieIncrease = charlieBalanceAfter - charlieBalanceBefore;
        
        // Verify FIFO: Alice processed first, then Bob, then Charlie gets nothing
        assertTrue(aliceIncrease > 0, "Alice should be processed first");
        assertEq(charlieIncrease, 0, "Charlie should NOT be processed (FIFO - last in queue)");
        
        // Alice should have smaller increase than Bob since Alice had smaller queue amount
        assertTrue(aliceIncrease < bobIncrease, "Alice should have smaller redemption than Bob (different queue amounts)");
        
        // Queue should still have pending redemptions (Charlie and possibly remaining Bob)
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should still have pending redemptions");
    }

    // ============================================
    // 4. Integration with Contract State Tests
    // ============================================

    function testRedeemAndOrQueue_RespectsMaxRedeemLimits() public {
        uint256 depositAmount = 1000000;
        uint256 excessiveRedeemAmount = 2000000; // More than available
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        uint256 maxRedeemableShares = bullaFactoring.maxRedeem(alice);
        
        vm.prank(alice);
        (uint256 redeemedAssets, uint256 queuedShares) = bullaFactoring.redeemAndOrQueue(excessiveRedeemAmount, alice, alice);
        
        assertTrue(redeemedAssets <= maxRedeemableShares, "Should not exceed max redeemable");
        assertEq(queuedShares, excessiveRedeemAmount - redeemedAssets, "Should queue excess");
    }

    // ============================================
    // 5. Edge Cases and Error Conditions
    // ============================================

    function testQueueRedemption_WithZeroShares() public {
        vm.prank(alice);
        bullaFactoring.deposit(1000000, alice);
        
        vm.prank(alice);
        (uint256 redeemedAssets, uint256 queuedShares) = bullaFactoring.redeemAndOrQueue(0, alice, alice);
        
        assertEq(redeemedAssets, 0, "Should redeem nothing");
        assertEq(queuedShares, 0, "Should queue nothing");
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should remain empty");
    }

    function testQueueProcessing_OwnerInsufficientBalance() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 500000;
        
        // Alice deposits and queues redemption
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Create liquidity constraint
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 9000, 0, 0);
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 9000, address(0));
        
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        uint256 aliceShares = bullaFactoring.balanceOf(alice);

        // Alice transfers away her shares
        vm.prank(alice);
        bullaFactoring.transfer(bob, aliceShares);
        
        // Pay invoice to restore liquidity
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 800000);
        
        // Processing should skip Alice's redemption due to insufficient balance
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        
        assertEq(aliceBalanceAfter, aliceBalanceBefore, "Alice should not receive anything");
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty after transfer");
    }

    // ============================================
    // 6. Queue State Management Tests
    // ============================================

    function testGetNextRedemption_ReturnsCorrectData() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 300000;
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Create liquidity constraint and queue
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 9000, 0, 0);
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 9000, address(0));
        
        vm.prank(alice);
        (, uint256 queuedShares) = bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        IRedemptionQueue.QueuedRedemption memory redemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        
        assertEq(redemption.owner, alice, "Owner should be Alice");
        assertEq(redemption.receiver, alice, "Receiver should be Alice");
        assertEq(redemption.shares, queuedShares, "Shares should match queued amount");
        assertEq(redemption.assets, 0, "Assets should be 0 for share-based redemption");
    }

    // ============================================
    // 7. Complex Scenarios
    // ============================================

    function testMixedShareAndAssetRedemptions() public {
        uint256 depositAmount = 1000000;
        
        // Multiple users deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Create liquidity constraint
        vm.prank(david);
        uint256 invoiceId = createClaim(david, eve, 2500000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0);
        vm.prank(david);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(david);
        bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        
        // Mixed redemption types
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(depositAmount, alice, alice); // Share-based
        
        vm.prank(bob);
        bullaFactoring.withdrawAndOrQueue(depositAmount, bob, bob); // Asset-based
        
        vm.prank(charlie);
        bullaFactoring.redeemAndOrQueue(depositAmount, charlie, charlie); // Share-based
        
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should have mixed redemptions");
        
        // Read balances before triggering queue processing
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 charlieBalanceBefore = asset.balanceOf(charlie);
        
        // Add limited liquidity through deposits - enough for only Alice's redemption (1M + buffer)
        vm.prank(david);
        bullaFactoring.deposit(1100000, david); // Only enough for Alice's redemption + some for Bob
        
        // Verify FIFO processing works with mixed types
        uint256 aliceIncrease = asset.balanceOf(alice) - aliceBalanceBefore;
        uint256 bobIncrease = asset.balanceOf(bob) - bobBalanceBefore;  
        uint256 charlieIncrease = asset.balanceOf(charlie) - charlieBalanceBefore;
        
        // Alice should be processed first (FIFO), Charlie should not be processed
        assertTrue(aliceIncrease > 0, "Alice should be processed (first in FIFO)");
        assertEq(charlieIncrease, 0, "Charlie should NOT be processed yet (FIFO order)");
        
        // Bob might get partially processed if there's enough liquidity after Alice
        // Verify queue still has pending redemptions
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should still have pending redemptions");
    }

    // ============================================
    // 8. Permission and Access Control
    // ============================================

    function testQueueRespects_PermissionChanges() public {
        uint256 depositAmount = 1000000;
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Queue redemption
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(500000, alice, alice);
        
        // Remove Alice's redeem permissions
        vm.prank(address(this));
        redeemPermissions.disallow(alice);
        
        // Attempt to queue another redemption should fail
        vm.prank(alice);
        vm.expectRevert();
        bullaFactoring.redeemAndOrQueue(200000, alice, alice);
    }

    // ============================================
    // 10. Multiple Operation Integration
    // ============================================

    function testDeposit_FollowedByQueueProcessing() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 500000;
        uint256 newDeposit = 500000;
        
        // Setup queued redemption
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 9000, 0, 0);

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, 9000, address(0));
        vm.stopPrank();
        
        vm.startPrank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        vm.stopPrank();

        IRedemptionQueue.QueuedRedemption memory nextRedemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        
        // New deposit should trigger queue processing
        vm.prank(bob);
        bullaFactoring.deposit(newDeposit, bob);

        nextRedemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        
        assertGt(asset.balanceOf(alice), aliceBalanceBefore, "Alice should receive processed redemption");
    }

    function testFundInvoice_FollowedByQueueProcessing() public {
        uint256 depositAmount = 2000000;
        uint256 queueAmount = 300000;
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // First invoice reduces liquidity
        vm.prank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, 1000, 100, 9000, 0, 0);
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId1, 9000, address(0));
        
        // Queue redemption
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        // Second invoice funding shouldn't trigger processing (no new liquidity)
        vm.prank(charlie);
        uint256 invoiceId2 = createClaim(charlie, alice, 500000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, 1000, 100, 8000, 0, 0);
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(charlie);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        vm.prank(charlie);
        bullaFactoring.fundInvoice(invoiceId2, 8000, address(0));
        
        // Should not have processed queue (no additional liquidity)
        assertEq(asset.balanceOf(alice), aliceBalanceBefore, "Alice balance should be unchanged");
    }

    function testInvoicePayment_FollowedByAutomaticProcessing() public {
        uint256 depositAmount = 1000000;
        uint256 queueAmount = 300000;
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, eve, 800000, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 9000, 0, 0);
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 9000, address(0));
        
        vm.prank(alice);
        bullaFactoring.redeemAndOrQueue(queueAmount, alice, alice);
        
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        
        // Pay invoice and reconcile
        vm.prank(eve);
        bullaClaim.payClaim(invoiceId, 800000);
        
        bullaFactoring.reconcileActivePaidInvoices();
        
        assertGt(asset.balanceOf(alice), aliceBalanceBefore, "Alice should receive processed redemption");
    }
} 