// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IRedemptionQueue} from "../../contracts/interfaces/IRedemptionQueue.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
import {EIP712Helper} from "./utils/EIP712Helper.sol";

/**
 * @title TestRedemptionQueueInsufficientFunds
 * @notice Tests the behavior of the redemption queue when an owner no longer has 
 *         sufficient shares/assets for their queued redemption
 * @dev Documents that the queue SKIPS invalid items (both share-based and asset-based)
 *      and continues processing the next items in queue.
 * 
 * IMPORTANT: The queue is processed during invoice payment callback (reconcileSingleInvoice),
 *            so balances must be captured BEFORE calling payClaim.
 * 
 * EXPECTED BEHAVIOR (after fix):
 * - Share-based redemptions: When owner has insufficient shares, queue SKIPS and continues
 * - Asset-based withdrawals: When owner has insufficient shares, queue SKIPS and continues
 */
contract TestRedemptionQueueInsufficientFunds is CommonSetup {
    
    EIP712Helper public sigHelper;
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

        // Set up permitCreateClaim for Bob
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

        // Setup david and eve with more tokens
        deal(address(asset), david, 100000000);
        deal(address(asset), eve, 100000000);
        
        // Grant permissions for david and eve
        depositPermissions.allow(david);
        depositPermissions.allow(eve);
        redeemPermissions.allow(david);
        redeemPermissions.allow(eve);
        factoringPermissions.allow(david);
        factoringPermissions.allow(eve);
        
        // Approve asset for david and eve
        vm.prank(david);
        asset.approve(address(bullaFactoring), type(uint256).max);
        
        vm.prank(eve);
        asset.approve(address(bullaFactoring), type(uint256).max);
        
        // Approve bullaClaim for all users who might pay claims
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

    /**
     * @notice Helper to create a claim using bob as creditor (he has permissions)
     */
    function fundInvoiceAndDrainLiquidity(uint256 amount) internal returns (uint256) {
        // Bob creates claim with alice as debtor
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, amount, dueBy);
        
        // Underwriter approves
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0);
        
        // Bob approves NFT transfer
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        // Bob funds invoice
        vm.prank(bob);
        bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        
        return invoiceId;
    }

    // ============================================
    // Share-Based Redemption Tests
    // ============================================

    /**
     * @notice Test that when the first owner in queue has transferred their shares (share-based),
     *         the queue skips them and continues processing the next owner
     */
    function test_ShareBasedRedemption_QueueSkipsOwnerWithInsufficientShares() public {
        uint256 depositAmount = 1000000;
        
        // Alice and Bob both deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        // Add charlie's deposit
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Fund an invoice to use ALL liquidity so both must queue entirely
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(3000000);
        
        // Verify no liquidity remains
        assertEq(bullaFactoring.maxRedeem(), 0, "Should have no liquidity for redemptions");
        
        // Alice queues first - everything should go to queue since no liquidity
        vm.prank(alice);
        bullaFactoring.redeem(500000, alice, alice);
        
        // Bob queues second
        vm.prank(bob);
        bullaFactoring.redeem(500000, bob, bob);
        
        // Verify both are in queue
        assertEq(bullaFactoring.getRedemptionQueue().getQueueLength(), 2, "Queue should have 2 items");
        
        // Verify first item is share-based
        IRedemptionQueue.QueuedRedemption memory firstRedemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        assertTrue(firstRedemption.shares > 0, "First redemption should be share-based");
        
        // Alice transfers ALL her shares away before queue is processed
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        // Verify Alice no longer has shares
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have 0 shares after transfer");
        
        // Capture Bob's balance BEFORE payClaim (which processes queue via callback)
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Pay invoice - this triggers reconcileSingleInvoice which processes the queue
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 3000000);
        
        // Check results - queue was processed during the callback
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Bob SHOULD have received his redemption - the queue skipped Alice and processed Bob
        assertTrue(bobBalanceAfter > bobBalanceBefore, "Bob SHOULD be processed - queue continues after skipping Alice");
        
        // Queue should be empty after callback processing
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty after processing");
    }

    // ============================================
    // Asset-Based Withdrawal Tests
    // ============================================

    /**
     * @notice Test that when the first owner in queue (asset-based withdrawal) has transferred 
     *         their shares, the queue SKIPS them and continues (after fix)
     */
    function test_AssetBasedWithdrawal_QueueSkipsOwnerWithNoShares() public {
        uint256 depositAmount = 1000000;
        
        // Alice and Bob both deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        // Fund an invoice to use ALL liquidity (use charlie as external depositor to provide funds)
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(3000000);
        
        // Verify no liquidity
        assertEq(bullaFactoring.maxRedeem(), 0, "Should have no liquidity for redemptions");
        
        // Alice queues asset-based withdrawal
        vm.prank(alice);
        bullaFactoring.withdraw(500000, alice, alice);
        
        // Bob queues asset-based withdrawal
        vm.prank(bob);
        bullaFactoring.withdraw(500000, bob, bob);
        
        // Verify both are in queue
        assertEq(bullaFactoring.getRedemptionQueue().getQueueLength(), 2, "Queue should have 2 items");
        
        // Verify first item is asset-based (assets > 0)
        IRedemptionQueue.QueuedRedemption memory firstRedemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        assertTrue(firstRedemption.assets > 0, "First redemption should be asset-based");
        assertEq(firstRedemption.owner, alice, "First redemption should be Alice's");
        
        // Alice transfers ALL her shares away
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have 0 shares");
        
        // Capture Bob's balance BEFORE payClaim (which processes queue via callback)
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Pay invoice - this triggers queue processing via callback
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 3000000);
        
        // Check results
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Bob SHOULD be processed - queue skips Alice and continues
        assertTrue(bobBalanceAfter > bobBalanceBefore, "Bob SHOULD be processed - queue skips and continues");
        
        // Queue should be empty
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty after processing");
    }

    // ============================================
    // Mixed Scenario Tests
    // ============================================

    /**
     * @notice Test that share-based redemption with insufficient shares skips,
     *         then asset-based withdrawal after it gets processed
     */
    function test_ShareBasedFirst_DoesNotBlockAssetBased() public {
        uint256 depositAmount = 1000000;
        
        // Alice and Bob both deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Fund an invoice to use ALL liquidity
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(3000000);
        
        // Alice queues share-based redemption (should skip if no shares)
        vm.prank(alice);
        bullaFactoring.redeem(500000, alice, alice);
        
        // Bob queues asset-based withdrawal
        vm.prank(bob);
        bullaFactoring.withdraw(500000, bob, bob);
        
        // Verify queue structure
        IRedemptionQueue.QueuedRedemption memory firstRedemption = bullaFactoring.getRedemptionQueue().getNextRedemption();
        assertTrue(firstRedemption.shares > 0, "First should be share-based");
        
        // Alice transfers ALL her shares
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        // Capture balance BEFORE payClaim
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Pay invoice - triggers queue processing
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 3000000);
        
        // Share-based skips Alice, then Bob's asset-based should be processed
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        assertTrue(bobBalanceAfter > bobBalanceBefore, "Bob SHOULD be processed - share-based skips invalid owner");
        
        // Queue should be empty
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
    }

    /**
     * @notice Test that asset-based withdrawal with insufficient shares skips,
     *         then share-based redemption after it gets processed
     */
    function test_AssetBasedFirst_DoesNotBlockShareBased() public {
        uint256 depositAmount = 1000000;
        
        // Alice and Bob both deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Fund an invoice to use ALL liquidity
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(3000000);
        
        // Alice queues asset-based withdrawal (should skip if no shares)
        vm.prank(alice);
        bullaFactoring.withdraw(500000, alice, alice);
        
        // Bob queues share-based redemption
        vm.prank(bob);
        bullaFactoring.redeem(500000, bob, bob);
        
        // Alice transfers ALL her shares
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        // Capture balance BEFORE payClaim
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Pay invoice - triggers queue processing
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 3000000);
        
        // Asset-based skips Alice, then Bob's share-based should be processed
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        assertTrue(bobBalanceAfter > bobBalanceBefore, "Bob SHOULD be processed - asset-based skips invalid owner");
        
        // Queue should be empty
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
    }

    // ============================================
    // Edge Cases - All Items Invalid
    // ============================================

    /**
     * @notice Test queue empties gracefully when all share-based items have no owner shares
     */
    function test_AllShareBasedInvalid_QueueEmpties() public {
        uint256 depositAmount = 1000000;
        
        // Alice and Bob both deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        // Charlie deposits too for invoice funding
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Fund an invoice to use ALL liquidity
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(3000000);
        
        // Both queue share-based redemptions
        vm.prank(alice);
        bullaFactoring.redeem(500000, alice, alice);
        
        vm.prank(bob);
        bullaFactoring.redeem(500000, bob, bob);
        
        // Both transfer their shares away to charlie
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        uint256 bobShares = bullaFactoring.balanceOf(bob);
        
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        vm.prank(bob);
        bullaFactoring.transfer(charlie, bobShares);
        
        // Pay invoice - triggers queue processing
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 3000000);
        
        // Queue should be empty (both skipped because neither has shares)
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
        
        // Note: Bob receives the invoice kickback (as original creditor) which is separate
        // from any redemption. The key assertion is that the queue is empty (both items skipped).
    }

    /**
     * @notice Test queue empties gracefully when all asset-based items have no owner shares
     */
    function test_AllAssetBasedInvalid_QueueEmpties() public {
        uint256 depositAmount = 1000000;
        
        // Alice and Bob both deposit
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        vm.prank(charlie);
        bullaFactoring.deposit(depositAmount, charlie);
        
        // Fund an invoice to use ALL liquidity
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(3000000);
        
        // Both queue asset-based withdrawals
        vm.prank(alice);
        bullaFactoring.withdraw(500000, alice, alice);
        
        vm.prank(bob);
        bullaFactoring.withdraw(500000, bob, bob);
        
        // Both transfer their shares away
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        uint256 bobShares = bullaFactoring.balanceOf(bob);
        
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        vm.prank(bob);
        bullaFactoring.transfer(charlie, bobShares);
        
        // Pay invoice - triggers queue processing
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 3000000);
        
        // Queue should be empty (both skipped because neither has shares)
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
        
        // Note: Bob receives the invoice kickback (as original creditor) which is separate
        // from any redemption. The key assertion is that the queue is empty (both items skipped).
    }

    // ============================================
    // Documentation Test
    // ============================================

    /**
     * @notice Test documenting maxWithdraw behavior
     * @dev maxWithdraw(owner) still returns 0 when owner has no shares,
     *      but the queue processing now uses pool liquidity check first
     */
    function test_DocumentMaxWithdrawBehavior() public {
        uint256 depositAmount = 1000000;
        
        // Setup: Alice deposits
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Bob deposits too
        vm.prank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        
        // Fund invoice to block liquidity
        uint256 invoiceId = fundInvoiceAndDrainLiquidity(2000000);
        
        // Transfer all of Alice's shares
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        vm.prank(alice);
        bullaFactoring.transfer(charlie, aliceShares);
        
        // maxWithdraw for alice should be 0 (no shares)
        uint256 maxWithdrawAlice = bullaFactoring.maxWithdraw(alice);
        assertEq(maxWithdrawAlice, 0, "maxWithdraw should be 0 for owner with no shares");
        
        // maxRedeem for the pool should be 0 (no liquidity) 
        uint256 maxRedeemPool = bullaFactoring.maxRedeem();
        assertEq(maxRedeemPool, 0, "maxRedeem should be 0 with no liquidity");
        
        // Pay invoice to restore liquidity
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, 2000000);
        
        // Now pool has liquidity but alice has no shares
        maxWithdrawAlice = bullaFactoring.maxWithdraw(alice);
        maxRedeemPool = bullaFactoring.maxRedeem();
        
        assertEq(maxWithdrawAlice, 0, "maxWithdraw for alice should STILL be 0 - she has no shares");
        assertTrue(maxRedeemPool > 0, "maxRedeem for pool should be > 0 - liquidity restored");
    }
}
