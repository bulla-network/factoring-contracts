// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";

/**
 * @title TestReconciliationOfPaidInvoices
 * @notice Tests automatic reconciliation behavior triggered by state-changing functions
 * @dev Tests scenarios where _reconcileActivePaidInvoices() is called internally by deposit(), fundInvoice(), redeemAndOrQueue(), etc.
 *      Focus is on automatic reconciliation, not manual reconcileActivePaidInvoices() calls
 */
contract TestReconciliationOfPaidInvoices is CommonSetup {

    function setUp() public override {
        super.setUp();
        
        // Allow charlie for deposits and redemptions for these tests
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
    }

    /*//////////////////////////////////////////////////////////////
                    AUTOMATIC RECONCILIATION ON DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_TriggersAutomaticReconciliation() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Initial setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay invoice to create a paid invoice that needs reconciliation
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not yet reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before deposit");

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(invoiceId);
        assertEq(gainBefore, 0, "Should have no recorded gain before reconciliation");

        // Charlie makes a deposit - this should trigger automatic reconciliation
        vm.startPrank(charlie);
        bullaFactoring.deposit(50000, charlie);
        vm.stopPrank();

        // Verify automatic reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain(invoiceId);
        (uint256[] memory paidInvoicesAfter, , , ) = bullaFactoring.viewPoolStatus();

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to automatic reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after automatic reconciliation");
        assertEq(paidInvoicesAfter.length, 0, "Should have no paid invoices after reconciliation");
    }

    /*//////////////////////////////////////////////////////////////
                    AUTOMATIC RECONCILIATION ON REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_RedeemAndOrQueue_TriggersAutomaticReconciliation() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay invoice
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before redemption");

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(invoiceId);
        assertEq(gainBefore, 0, "Should have no recorded gain before reconciliation");

        // Alice redeems shares - this should trigger automatic reconciliation
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 2;
        bullaFactoring.redeemAndOrQueue(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify automatic reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain(invoiceId);
        (uint256[] memory paidInvoicesAfter, , , ) = bullaFactoring.viewPoolStatus();

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to automatic reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after automatic reconciliation");
        assertEq(paidInvoicesAfter.length, 0, "Should have no paid invoices after reconciliation");
    }

    function test_Redeem_TriggersAutomaticReconciliation() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay invoice
        vm.warp(block.timestamp + 35 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before redemption");

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(invoiceId);
        assertEq(gainBefore, 0, "Should have no recorded gain before reconciliation");

        // Alice redeems shares using regular redeem() - this should trigger automatic reconciliation
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 3;
        bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify automatic reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain(invoiceId);
        (uint256[] memory paidInvoicesAfter, , , ) = bullaFactoring.viewPoolStatus();

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to automatic reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after automatic reconciliation");
        assertEq(paidInvoicesAfter.length, 0, "Should have no paid invoices after reconciliation");
    }

    function test_Withdraw_TriggersAutomaticReconciliation() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay invoice
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Verify invoice is paid but not reconciled
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 1, "Should have one paid invoice before withdrawal");

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(invoiceId);
        assertEq(gainBefore, 0, "Should have no recorded gain before reconciliation");

        // Alice withdraws assets using regular withdraw() - this should trigger automatic reconciliation
        vm.startPrank(alice);
        uint256 maxWithdraw = bullaFactoring.maxWithdraw(alice);
        uint256 assetsToWithdraw = maxWithdraw / 3;
        bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        // Verify automatic reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain(invoiceId);
        (uint256[] memory paidInvoicesAfter, , , ) = bullaFactoring.viewPoolStatus();

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to automatic reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after automatic reconciliation");
        assertEq(paidInvoicesAfter.length, 0, "Should have no paid invoices after reconciliation");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTIPLE AUTOMATIC RECONCILIATIONS
    //////////////////////////////////////////////////////////////*/

    function test_MultipleStateChanges_AllTriggerReconciliation() public {
        uint256 initialDeposit = 400000;
        uint256 invoiceAmount = 80000;
        
        // Initial setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund multiple invoices
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy + 10 days);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();

        // Pay first invoice
        vm.warp(block.timestamp + 20 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId1, invoiceAmount);
        vm.stopPrank();

        // Verify first invoice is paid
        (uint256[] memory paidInvoices1, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices1.length, 1, "Should have one paid invoice");

        uint256 pricePerShareBeforeFirstReconciliation = bullaFactoring.pricePerShare();

        // Charlie makes deposit - triggers reconciliation of first invoice
        vm.startPrank(charlie);
        bullaFactoring.deposit(50000, charlie);
        vm.stopPrank();

        // Verify first invoice was reconciled
        uint256 pricePerShareAfterFirstReconciliation = bullaFactoring.pricePerShare();
        uint256 gain1 = bullaFactoring.paidInvoicesGain(invoiceId1);
        assertGt(pricePerShareAfterFirstReconciliation, pricePerShareBeforeFirstReconciliation, "Price per share should increase after first reconciliation");
        assertGt(gain1, 0, "First invoice should be reconciled after deposit");

        // Pay second invoice
        vm.warp(block.timestamp + 15 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId2, invoiceAmount);
        vm.stopPrank();

        // Verify second invoice is paid but not reconciled
        (uint256[] memory paidInvoices2, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices2.length, 1, "Should have one paid invoice (the second one)");
        uint256 gain2Before = bullaFactoring.paidInvoicesGain(invoiceId2);
        assertEq(gain2Before, 0, "Second invoice should not be reconciled yet");

        uint256 pricePerShareBeforeSecondReconciliation = bullaFactoring.pricePerShare();

        // Alice redeems - triggers reconciliation of second invoice
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 4;
        bullaFactoring.redeemAndOrQueue(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify second invoice was reconciled
        uint256 pricePerShareAfterSecondReconciliation = bullaFactoring.pricePerShare();
        uint256 gain2After = bullaFactoring.paidInvoicesGain(invoiceId2);
        (uint256[] memory paidInvoicesFinal, , , ) = bullaFactoring.viewPoolStatus();

        assertGt(pricePerShareAfterSecondReconciliation, pricePerShareBeforeSecondReconciliation, "Price per share should increase after second reconciliation");
        assertGt(gain2After, 0, "Second invoice should be reconciled after redemption");
        assertEq(paidInvoicesFinal.length, 0, "Should have no paid invoices after final reconciliation");
    }

    /*//////////////////////////////////////////////////////////////
                    AUTOMATIC RECONCILIATION WITH FEES
    //////////////////////////////////////////////////////////////*/

    function test_AutomaticReconciliation_FeesAccumulation() public {
        uint256 initialDeposit = 250000;
        uint256 invoiceAmount = 100000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Pay invoice
        vm.warp(block.timestamp + 35 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Record fee balances before automatic reconciliation
        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 adminFeesBefore = bullaFactoring.adminFeeBalance();
        uint256 protocolFeesBefore = bullaFactoring.protocolFeeBalance();
        uint256 spreadGainsBefore = bullaFactoring.spreadGainsBalance();

        // Charlie deposits - triggers automatic reconciliation
        vm.startPrank(charlie);
        bullaFactoring.deposit(100000, charlie);
        vm.stopPrank();

        // Verify fees were accumulated during automatic reconciliation
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 adminFeesAfter = bullaFactoring.adminFeeBalance();
        uint256 protocolFeesAfter = bullaFactoring.protocolFeeBalance();
        uint256 spreadGainsAfter = bullaFactoring.spreadGainsBalance();

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to automatic reconciliation");
        assertGt(adminFeesAfter, adminFeesBefore, "Admin fees should increase from automatic reconciliation");
        assertGt(protocolFeesAfter, protocolFeesBefore, "Protocol fees should increase from automatic reconciliation");
        assertGt(spreadGainsAfter, spreadGainsBefore, "Spread gains should increase from automatic reconciliation");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_AutomaticReconciliation_NoPaidInvoices() public {
        uint256 initialDeposit = 200000;
        
        // Setup with no invoices
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Record state before
        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 totalAssetsBefore = bullaFactoring.totalAssets();

        // Charlie deposits when there are no paid invoices to reconcile
        vm.startPrank(charlie);
        bullaFactoring.deposit(50000, charlie);
        vm.stopPrank();

        // Verify no unintended side effects
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 totalAssetsAfter = bullaFactoring.totalAssets();

        // Price per share should remain stable (or increase only due to deposits)
        assertApproxEqAbs(pricePerShareAfter, pricePerShareBefore, 1000, "Price per share should not change");
        assertEq(totalAssetsAfter, totalAssetsBefore + 50000, "Total assets should increase by deposit amount");
    }

    function test_AutomaticReconciliation_PartialPayment() public {
        uint256 initialDeposit = 200000;
        uint256 invoiceAmount = 100000;
        uint256 partialPayment = 60000;
        
        // Setup
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Make partial payment
        vm.warp(block.timestamp + 25 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), partialPayment);
        bullaClaim.payClaim(invoiceId, partialPayment);
        vm.stopPrank();

        // Verify invoice is partially paid but not detected as fully paid
        (uint256[] memory paidInvoicesBefore, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesBefore.length, 0, "Partially paid invoice should not appear in paid invoices");

        uint256 pricePerShareBeforePartialDeposit = bullaFactoring.pricePerShare();

        // Charlie deposits - automatic reconciliation should not affect partial payment
        vm.startPrank(charlie);
        bullaFactoring.deposit(50000, charlie);
        vm.stopPrank();

        uint256 pricePerShareAfterPartialDeposit = bullaFactoring.pricePerShare();
        assertApproxEqAbs(pricePerShareAfterPartialDeposit, pricePerShareBeforePartialDeposit, 1000, "Price per share should not change after partial deposit");

        // Complete payment
        uint256 remainingPayment = invoiceAmount - partialPayment;
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), remainingPayment);
        bullaClaim.payClaim(invoiceId, remainingPayment);
        vm.stopPrank();

        // Verify invoice is now fully paid
        (uint256[] memory paidInvoicesAfter, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesAfter.length, 1, "Fully paid invoice should appear in paid invoices");

        uint256 pricePerShareBeforeFinalDeposit = bullaFactoring.pricePerShare();

        // Another deposit should trigger reconciliation of the fully paid invoice
        vm.startPrank(charlie);
        bullaFactoring.deposit(25000, charlie);
        vm.stopPrank();

        // Verify reconciliation occurred
        uint256 pricePerShareAfterFinalDeposit = bullaFactoring.pricePerShare();
        uint256 gain = bullaFactoring.paidInvoicesGain(invoiceId);
        
        // The key assertion: reconciliation should cause a significant price increase beyond normal deposit effects
        uint256 reconciliationIncrease = pricePerShareAfterFinalDeposit - pricePerShareBeforeFinalDeposit;
        uint256 normalDepositIncrease = pricePerShareAfterPartialDeposit - pricePerShareBeforePartialDeposit;
        
        assertGt(reconciliationIncrease, normalDepositIncrease, "Reconciliation should cause larger price increase than normal deposit");
        assertGt(pricePerShareAfterFinalDeposit, pricePerShareBeforeFinalDeposit, "Price per share should increase after full payment reconciliation");
        assertGt(gain, 0, "Should have recorded gain after full payment reconciliation");
    }
} 