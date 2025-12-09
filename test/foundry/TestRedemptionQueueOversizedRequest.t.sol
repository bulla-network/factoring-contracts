// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "contracts/interfaces/IRedemptionQueue.sol";

/// @title Test case to confirm oversized redemption requests are capped to user's balance
contract TestRedemptionQueueOversizedRequest is CommonSetup {
    
    function setUp() public override {
        super.setUp();
    }
    
    /// @notice Test that a redemption request for more shares than owned is capped to balance
    function testRedeemRequestIsCappedToBalance() public {
        uint256 depositAmount = 10000e6; // 10k USDC (6 decimals)
        
        // Alice deposits 10k
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        uint256 oversizedRequest = aliceShares * 10; // Request 10x more shares than owned
        
        // Fund invoice to exhaust liquidity so redemptions get queued
        uint256 invoiceAmount = 10000e6;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Get remaining liquidity after invoice funding
        uint256 immediateRedeemable = bullaFactoring.maxRedeem(alice);
        
        // Alice tries to redeem 10x more shares than she owns
        vm.prank(alice);
        bullaFactoring.redeem(oversizedRequest, alice, alice);
        
        // The request should be capped to Alice's actual balance
        (uint256 queuedShares, ) = bullaFactoring.getRedemptionQueue().getTotalQueuedForOwner(alice);
        uint256 expectedQueuedShares = aliceShares - immediateRedeemable;
        assertEq(queuedShares, expectedQueuedShares, "Queued shares should be capped to balance minus immediate redemption");
        
        // Verify total (redeemed + queued) equals Alice's original balance, not the oversized request
        assertEq(immediateRedeemable + queuedShares, aliceShares, "Total redeemed + queued should equal original balance");
    }
    
    /// @notice Test that a withdrawal request for more assets than owned is capped
    function testWithdrawRequestIsCappedToBalance() public {
        uint256 depositAmount = 10000e6; // 10k USDC (6 decimals)
        
        // Alice deposits 10k
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        uint256 aliceMaxWithdraw = bullaFactoring.maxWithdraw(alice);
        uint256 oversizedRequest = aliceMaxWithdraw * 10; // Request 10x more assets than available
        
        // Fund invoice to exhaust liquidity so withdrawals get queued
        uint256 invoiceAmount = 10000e6;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Get Alice's max assets (what her shares are worth)
        uint256 aliceMaxAssets = bullaFactoring.previewRedeem(bullaFactoring.balanceOf(alice));
        uint256 immediateWithdrawable = bullaFactoring.maxWithdraw(alice);
        
        // Alice tries to withdraw 10x more assets than she can
        vm.prank(alice);
        bullaFactoring.withdraw(oversizedRequest, alice, alice);
        
        // The request should be capped to Alice's max assets
        (, uint256 queuedAssets) = bullaFactoring.getRedemptionQueue().getTotalQueuedForOwner(alice);
        uint256 expectedQueuedAssets = aliceMaxAssets - immediateWithdrawable;
        assertEq(queuedAssets, expectedQueuedAssets, "Queued assets should be capped to max assets minus immediate withdrawal");
        
        // Verify total (withdrawn + queued) equals Alice's max assets, not the oversized request
        assertEq(immediateWithdrawable + queuedAssets, aliceMaxAssets, "Total withdrawn + queued should equal max assets from shares");
    }
}
