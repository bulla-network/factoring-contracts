// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";

/**
 * @title TestReconciliationOfPaidInvoices
 * @notice Tests automatic reconciliation behavior triggered by state-changing functions
 * @dev Tests scenarios where _reconcilePaid() is called internally by deposit(), fundInvoice(), redeem(), etc.
 *      Focus is on automatic reconciliation, not manual reconcilePaid() calls
 */
contract TestReconciliationOfPaidInvoices is CommonSetup {

    function setUp() public override {
        super.setUp();
        
        // Allow charlie for deposits and redemptions for these tests
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
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

        // Note: With the new model, active invoices are always unpaid.
        // Once paid, invoices are automatically reconciled and removed from active invoices.

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain();
        // Since paidInvoicesGain is now cumulative, we store the current total before reconciliation

        // Manually trigger reconciliation first (since redeem now blocks when active paid invoices exist)
        

        // Alice redeems shares
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 2;
        bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain();
        // Active invoices are always unpaid now

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after reconciliation");
        // Paid invoices are automatically reconciled in the new model
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

        // Note: With the new model, active invoices are always unpaid.
        // Once paid, invoices are automatically reconciled and removed from active invoices.

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain();
        // Since paidInvoicesGain is now cumulative, we store the current total before reconciliation

        // Manually trigger reconciliation first (since redeem now blocks when active paid invoices exist)
        

        // Alice redeems shares using regular redeem()
        vm.startPrank(alice);
        uint256 sharesToRedeem = bullaFactoring.balanceOf(alice) / 3;
        bullaFactoring.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        // Verify reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain();
        // Active invoices are always unpaid now

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after reconciliation");
        // Paid invoices are automatically reconciled in the new model
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

        // Note: With the new model, active invoices are always unpaid.
        // Once paid, invoices are automatically reconciled and removed from active invoices.

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        uint256 gainBefore = bullaFactoring.paidInvoicesGain();
        // Since paidInvoicesGain is now cumulative, we store the current total before reconciliation

        // Manually trigger reconciliation first (since withdraw now blocks when active paid invoices exist)
        

        // Alice withdraws assets using regular withdraw()
        vm.startPrank(alice);
        uint256 maxWithdraw = bullaFactoring.maxWithdraw(alice);
        uint256 assetsToWithdraw = maxWithdraw / 3;
        bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        // Verify reconciliation occurred
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        uint256 gainAfter = bullaFactoring.paidInvoicesGain();
        // Active invoices are always unpaid now

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase due to reconciliation");
        assertGt(gainAfter, 0, "Should have recorded gain after reconciliation");
        // Paid invoices are automatically reconciled in the new model
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
} 
