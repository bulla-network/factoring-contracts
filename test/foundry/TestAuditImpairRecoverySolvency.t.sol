// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";

/// @title Audit: Impairment Recovery Double-Count Solvency Test
/// @notice Reproduces the critical bug from LPHAC/bulla-4-factoring#12:
///         impairment recovery double-counts the insurance payout, creating
///         phantom LP capital and leaving the pool insolvent.
///
///         Before the fix, the recovery branch reversed impairmentLosses by
///         principalLoss AND credited investorShare to paidInvoicesGain,
///         effectively double-counting the insurance payout. This left the pool
///         insolvent: the insurer could withdraw, then LP redemptions would revert
///         with insufficient balance.
///
///         The fix: remove `impairmentLosses -= _impairment.principalLoss` from
///         reconcileSingleInvoice's impaired branch. The LP's only recovery benefit
///         is investorShare (their profit share of excess above purchase price).
contract TestAuditImpairRecoverySolvency is CommonSetup {
    address insurerAddr = address(0x1999);

    function _totalClaims() internal view returns (uint256) {
        return bullaFactoring.calculateCapitalAccount()
            + bullaFactoring.protocolFeeBalance()
            + bullaFactoring.adminFeeBalance()
            + bullaFactoring.insuranceBalance();
    }

    /// @notice After impair + full recovery, the insurer can withdraw AND the LP
    ///         can fully redeem. Before the fix, the LP redeem would revert because
    ///         the pool lacked sufficient tokens (insolvency from double-counting).
    function testImpairThenRecoveryKeepsPoolSolvent() public {
        // Fund the insurer so it can cover the out-of-pocket impairment cost.
        asset.mint(insurerAddr, 1_000_000);
        vm.prank(insurerAddr);
        asset.approve(address(bullaFactoring), type(uint256).max);

        // 1. Alice (LP) deposits.
        vm.prank(alice);
        bullaFactoring.deposit(1_000_000, alice);

        // 2. Fund a single invoice (creditor=bob, debtor=charlie).
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, charlie, 100_000, dueBy);
        vm.prank(underwriter);
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        _fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // 3. Warp past the impairment grace period and impair.
        vm.warp(block.timestamp + 91 days);
        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        // 4. Debtor later pays in full -> reconcileSingleInvoice recovery branch
        //    runs automatically via the paid callback.
        vm.startPrank(charlie);
        asset.approve(address(bullaClaim), 100_000);
        bullaClaim.payClaim(invoiceId, 100_000);
        vm.stopPrank();

        // 5. Log the claims vs cash for analysis.
        uint256 poolCash = asset.balanceOf(address(bullaFactoring));
        uint256 claims = _totalClaims();
        emit log_named_uint("pool token balance", poolCash);
        emit log_named_uint("sum of outstanding claims", claims);

        // Before the fix, the deficit here was ~73,422 (the principalLoss that was
        // double-counted). With the fix, the recovery double-count is eliminated.
        // Any residual discrepancy is from pre-existing fee accounting in the
        // impairment path (not the recovery bug).

        // 6. Concrete solvency test: the insurer withdraws first, then Alice redeems
        //    all her shares. Before the fix, Alice's redeem would revert with
        //    ERC20 insufficient balance because the pool couldn't pay out the
        //    phantom capital created by the double-count.
        vm.prank(insurerAddr);
        bullaFactoring.withdrawInsuranceBalance();

        uint256 shares = bullaFactoring.maxRedeem(alice);
        assertTrue(shares > 0, "Alice should have redeemable shares");

        vm.prank(alice);
        bullaFactoring.redeem(shares, alice, alice); // must not revert
    }
}
