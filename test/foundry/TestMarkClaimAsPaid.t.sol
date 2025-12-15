// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import './CommonSetup.t.sol';
import {Claim, Status} from "bulla-contracts-v2/src/types/Types.sol";

/**
 * @title TestMarkClaimAsPaid
 * @notice Exercises scenarios where a claim is marked as paid before the protocol
 *         approves or funds the invoice.
 *
 * BEHAVIORS UNDER TEST:
 * - If an attacker marks a claim as paid before underwriter approval, subsequent
 *   approval reverts and pool balances stay unchanged.
 * - If an attacker marks a claim as paid after approval but before funding,
 *   funding reverts and no assets move.
 *
 * EXPECTED OUTCOME:
 * - Already-paid claims cannot be approved or funded, preventing attacker profit
 *   and keeping pool/accounting balances intact.
 */
contract TestMarkClaimAsPaid is CommonSetup {
    function test_MarkAsPaidBeforeApproval() public {
        address attacker = makeAddr("attacker");
        factoringPermissions.allow(attacker);

        // Step 1: Alice deposits into the pool
        uint256 poolDeposit = 1_000_000e6;
        vm.prank(alice);
        bullaFactoring.deposit(poolDeposit, alice);

        uint256 poolBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 attackerBalanceBefore = asset.balanceOf(attacker);

        // Step 2: Attacker creates a claim
        uint256 invoiceAmount = 100_000e6;
        address fakeDebtor = makeAddr("fakeDebtor");
        vm.prank(attacker);
        uint256 claimId = createClaim(attacker, fakeDebtor, invoiceAmount, block.timestamp + 30 days);

        // Step 3: Attacker marks claim as paid (frontrunning the approval)
        vm.prank(attacker);
        bullaClaim.markClaimAsPaid(claimId);

        // Sanity check: status flipped but no funds moved
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.paidAmount, 0, "paidAmount should remain zero");
        assertEq(uint8(claim.status), uint8(Status.Paid), "claim should be marked as paid");

        // Step 4: Underwriter approves
        vm.prank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyPaid()"));
        bullaFactoring.approveInvoice(claimId, interestApr, spreadBps, upfrontBps, 0);

        uint256 attackerBalanceAfter = asset.balanceOf(attacker);
        uint256 poolBalanceAfter = asset.balanceOf(address(bullaFactoring));

        // EXPECTED: invoice should not be approved when it is already marked as paid
        assertEq(poolBalanceAfter, poolBalanceBefore, "Pool balance should remain unchanged for already-paid claims");
        assertEq(attackerBalanceAfter, attackerBalanceBefore, "Attacker should not profit without repayment");
        assertEq(bullaFactoring.totalAssets(), poolBalanceAfter, "totalAssets should track actual pool balance");
    }

    function test_MarkAsPaidBeforeFunding() public {
        address attacker = makeAddr("attacker");
        factoringPermissions.allow(attacker);

        // Step 1: Alice deposits into the pool
        uint256 poolDeposit = 1_000_000e6;
        vm.prank(alice);
        bullaFactoring.deposit(poolDeposit, alice);

        uint256 poolBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 attackerBalanceBefore = asset.balanceOf(attacker);

        // Step 2: Attacker creates a claim
        uint256 invoiceAmount = 100_000e6;
        address fakeDebtor = makeAddr("fakeDebtor");
        vm.prank(attacker);
        uint256 claimId = createClaim(attacker, fakeDebtor, invoiceAmount, block.timestamp + 30 days);

        // Step 3: Underwriter approves
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(claimId, interestApr, spreadBps, upfrontBps, 0);

        // Step 4: Attacker marks claim as paid (frontrunning the approval)
        vm.prank(attacker);
        bullaClaim.markClaimAsPaid(claimId);

        // Sanity check: status flipped but no funds moved
        Claim memory claim = bullaClaim.getClaim(claimId);
        assertEq(claim.paidAmount, 0, "paidAmount should remain zero");
        assertEq(uint8(claim.status), uint8(Status.Paid), "claim should be marked as paid");

        vm.startPrank(attacker);
        bullaClaim.approve(address(bullaFactoring), claimId);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyPaid()"));
        bullaFactoring.fundInvoice(claimId, upfrontBps, attacker);

        uint256 attackerBalanceAfter = asset.balanceOf(attacker);
        uint256 poolBalanceAfter = asset.balanceOf(address(bullaFactoring));

        // EXPECTED: invoice should not be funded when it is already marked as paid
        assertEq(poolBalanceAfter, poolBalanceBefore, "Pool balance should remain unchanged for already-paid claims");
        assertEq(attackerBalanceAfter, attackerBalanceBefore, "Attacker should not profit without repayment");
        assertEq(bullaFactoring.totalAssets(), poolBalanceAfter, "totalAssets should track actual pool balance");
    }
}

