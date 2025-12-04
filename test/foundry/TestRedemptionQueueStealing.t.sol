// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "contracts/interfaces/IRedemptionQueue.sol";

/// @title Test case to confirm redemption queue protection against stealing
/// @notice This test demonstrates that an attacker CANNOT queue a redemption 
///         for another owner without approval - the allowance check prevents theft
contract TestRedemptionQueueStealing is CommonSetup {
    
    address attacker;
    address victim;
    
    function setUp() public override {
        super.setUp();
        
        attacker = alice;
        victim = bob;
        
        // Add charlie as an additional investor
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
    }
    
    /// @notice Test that queueing redemption for another owner requires approval (fixed)
    /// @dev When queueing shares, the contract now properly consumes allowance
    function testCannotQueueRedemptionForOtherOwnerWithoutApproval() public {
        uint256 depositAmount = 10000e6; // 10k USDC (6 decimals)
        
        // Setup: Both attacker and victim deposit 10k each
        vm.prank(attacker);
        bullaFactoring.deposit(depositAmount, attacker);
        
        vm.prank(victim);
        bullaFactoring.deposit(depositAmount, victim);
        
        uint256 victimInitialShares = bullaFactoring.balanceOf(victim);
        
        // Verify attacker has NO allowance from victim
        assertEq(bullaFactoring.allowance(victim, attacker), 0, "Attacker should have zero allowance from victim");
        
        // Fund invoice to exhaust liquidity (25k invoice at 80% upfront = 20k funded)
        uint256 invoiceAmount = 25000e6;
        vm.prank(victim);
        uint256 invoiceId = createClaim(victim, attacker, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(victim);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Create initial queue entry (attacker queues their own shares first)
        vm.prank(charlie);
        bullaFactoring.deposit(100e6, charlie);
        vm.prank(charlie);
        bullaFactoring.redeem(100e6, charlie, charlie);
        
        // If queue still empty, attacker queues their own shares
        if (bullaFactoring.getRedemptionQueue().isQueueEmpty()) {
            uint256 attackerShares = bullaFactoring.balanceOf(attacker);
            vm.prank(attacker);
            bullaFactoring.redeem(attackerShares, attacker, attacker);
        }
        
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue must not be empty for attack");
        
        // ATTACK ATTEMPT: Try to queue redemption for victim's shares - should FAIL
        // The fix now properly consumes allowance when queueing shares
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                attacker,
                0,
                victimInitialShares
            )
        );
        bullaFactoring.redeem(victimInitialShares, attacker, victim);
        
        // Verify victim's shares are NOT queued (attack was blocked)
        (uint256 queuedForVictim, ) = bullaFactoring.getRedemptionQueue().getTotalQueuedForOwner(victim);
        assertEq(queuedForVictim, 0, "Victim's shares should not be queued");
        
        // Verify victim's shares are intact
        assertEq(bullaFactoring.balanceOf(victim), victimInitialShares, "Victim's shares should remain unchanged");
    }
    
    /// @notice Test that redeeming for another investor WITHOUT approval reverts when queue is empty
    /// @dev This is the expected ERC4626 behavior - allowance check should prevent unauthorized redemptions
    function testCannotRedeemForOtherInvestorWithoutApproval() public {
        uint256 depositAmount = 10000e6;
        
        // Both investors deposit
        vm.prank(attacker);
        bullaFactoring.deposit(depositAmount, attacker);
        
        vm.prank(victim);
        bullaFactoring.deposit(depositAmount, victim);
        
        uint256 victimShares = bullaFactoring.balanceOf(victim);
        
        // Verify queue is empty (normal operation)
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
        
        // Verify attacker has NO allowance from victim
        assertEq(bullaFactoring.allowance(victim, attacker), 0, "Attacker should have zero allowance");
        
        // Attacker tries to redeem victim's shares - should revert with insufficient allowance
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                attacker,
                0,
                victimShares
            )
        );
        bullaFactoring.redeem(victimShares, attacker, victim);
        
        // Victim's shares should remain untouched
        assertEq(bullaFactoring.balanceOf(victim), victimShares, "Victim's shares should be unchanged");
    }

    /// @notice Test that queueing withdrawal for another owner requires approval (via withdraw function)
    /// @dev When queueing assets via withdraw, the contract now properly consumes allowance
    function testCannotQueueWithdrawForOtherOwnerWithoutApproval() public {
        uint256 depositAmount = 10000e6; // 10k USDC (6 decimals)
        
        // Setup: Both attacker and victim deposit 10k each
        vm.prank(attacker);
        bullaFactoring.deposit(depositAmount, attacker);
        
        vm.prank(victim);
        bullaFactoring.deposit(depositAmount, victim);
        
        uint256 victimInitialShares = bullaFactoring.balanceOf(victim);
        
        // Verify attacker has NO allowance from victim
        assertEq(bullaFactoring.allowance(victim, attacker), 0, "Attacker should have zero allowance from victim");
        
        // Fund invoice to exhaust liquidity
        uint256 invoiceAmount = 25000e6;
        vm.prank(victim);
        uint256 invoiceId = createClaim(victim, attacker, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(victim);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Create initial queue entry
        vm.prank(charlie);
        bullaFactoring.deposit(100e6, charlie);
        vm.prank(charlie);
        bullaFactoring.redeem(100e6, charlie, charlie);
        
        // If queue still empty, attacker queues their own shares
        if (bullaFactoring.getRedemptionQueue().isQueueEmpty()) {
            uint256 attackerShares = bullaFactoring.balanceOf(attacker);
            vm.prank(attacker);
            bullaFactoring.redeem(attackerShares, attacker, attacker);
        }
        
        assertFalse(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue must not be empty for attack");
        
        // Calculate the shares that would be required for the withdrawal
        uint256 sharesToSpend = bullaFactoring.previewWithdraw(depositAmount);
        
        // ATTACK ATTEMPT: Try to queue withdrawal for victim's assets - should FAIL
        // The fix now properly consumes allowance when queueing assets
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                attacker,
                0,
                sharesToSpend
            )
        );
        bullaFactoring.withdraw(depositAmount, attacker, victim);
        
        // Verify victim's shares are NOT queued (attack was blocked)
        (, uint256 queuedAssetsForVictim) = bullaFactoring.getRedemptionQueue().getTotalQueuedForOwner(victim);
        assertEq(queuedAssetsForVictim, 0, "Victim's assets should not be queued");
        
        // Verify victim's shares are intact
        assertEq(bullaFactoring.balanceOf(victim), victimInitialShares, "Victim's shares should remain unchanged");
    }
}
