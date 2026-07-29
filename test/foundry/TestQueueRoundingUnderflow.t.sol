// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";

/// @title Regression test for processRedemptionQueue rounding underflow
/// @notice Verifies that asset-based queued withdrawals don't revert when
///         sharesToBurn (ceil) exceeds maxRedeemableShares (floor) on a full drain.
contract TestQueueRoundingUnderflow is CommonSetup {
    address depositor = address(0xD001);

    function setUp() public override {
        super.setUp();
        // Allow depositor for deposit + redeem + mint funds
        permitUser(depositor, false, 2_000_000);
    }

    /// @notice Reproduces the underflow: deposit triggers processRedemptionQueue,
    ///         which tries to fulfil an asset-based queue entry that drains all
    ///         free liquidity. ceil(x) > floor(x) when price != 1:1, causing
    ///         maxRedeemableShares -= sharesToBurn to panic with 0x11.
    function testDepositDoesNotRevertWhenQueueDrainsAllLiquidity() public {
        // 1. Depositor deposits 1,000,000
        vm.prank(depositor);
        bullaFactoring.deposit(1_000_000, depositor);

        // 2. Fund a small invoice and repay it to realise interest,
        //    pushing price off 1:1 so convertToShares != previewWithdraw
        vm.prank(bob);
        uint256 smallInvoiceId = createClaim(bob, alice, 10_000, dueBy);
        vm.prank(underwriter);
        _approveInvoice(smallInvoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), smallInvoiceId);
        _fundInvoice(smallInvoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Warp 30 days so interest accrues
        vm.warp(block.timestamp + 30 days);

        // Alice (debtor) pays the small invoice in full
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 10_000);
        bullaClaim.payClaim(smallInvoiceId, 10_000);
        vm.stopPrank();

        // Verify price is off 1:1
        uint256 capitalAccount = bullaFactoring.calculateCapitalAccount();
        uint256 totalSupply = bullaFactoring.totalSupply();
        assertTrue(capitalAccount != totalSupply, "Price should be off 1:1 after realised interest");

        // 3. Fund a large invoice to lock up most of the pool's liquidity
        vm.prank(bob);
        uint256 largeInvoiceId = createClaim(bob, alice, 1_200_000, block.timestamp + 30 days);
        vm.prank(underwriter);
        _approveInvoice(largeInvoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), largeInvoiceId);
        _fundInvoice(largeInvoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Free liquidity is now small
        uint256 freeLiquidity = bullaFactoring.totalAssets();
        assertTrue(freeLiquidity > 0, "Should have some free liquidity");
        assertTrue(freeLiquidity < 100_000, "Free liquidity should be small");

        // 4. Depositor withdraws full position — most will be queued as asset-based entry
        uint256 depositorShares = bullaFactoring.balanceOf(depositor);
        uint256 depositorAssets = bullaFactoring.previewRedeem(depositorShares);
        vm.prank(depositor);
        bullaFactoring.withdraw(depositorAssets, depositor, depositor);

        // 5. Another user deposits — this triggers processRedemptionQueue.
        //    Before the fix, this reverted with panic 0x11 (arithmetic underflow)
        //    because sharesToBurn (ceil) > maxRedeemableShares (floor).
        address newDepositor = address(0xD002);
        permitUser(newDepositor, false, 10_000);
        vm.prank(newDepositor);
        bullaFactoring.deposit(3_333, newDepositor);

        // If we reach here, the fix works — no underflow
        assertTrue(true, "Deposit succeeded without underflow");
    }
}
