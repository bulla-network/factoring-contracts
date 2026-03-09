// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";

/**
 * @title TestUpfrontProtocolFee
 * @notice Tests that protocolFee is realized immediately at funding time
 *         rather than at reconciliation or unfactoring.
 */
contract TestUpfrontProtocolFee is CommonSetup {

    function setUp() public override {
        super.setUp();
    }

    /// @notice Verify protocolFeeBalance increments at funding time
    function test_ProtocolFeeRealizedAtFunding() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create and approve invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        assertEq(protocolFeeBalanceBefore, 0, "Protocol fee balance should be 0 before funding");

        // Fund invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        assertTrue(protocolFeeBalanceAfter > 0, "Protocol fee balance should be > 0 after funding");

        // Verify the protocol fee amount is correct
        (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        assertEq(protocolFeeBalanceAfter, expectedProtocolFee, "Protocol fee balance should match calculated protocol fee");
    }

    /// @notice Verify protocol can withdraw fees immediately after funding (before invoice is paid)
    function test_ProtocolCanWithdrawImmediatelyAfterFunding() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create, approve, and fund invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 protocolFeeBalance = bullaFactoring.protocolFeeBalance();
        assertTrue(protocolFeeBalance > 0, "Should have protocol fees to withdraw");

        uint256 bullaDaoBalanceBefore = asset.balanceOf(bullaDao);

        // Protocol withdraws fees before invoice is paid
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        uint256 bullaDaoBalanceAfter = asset.balanceOf(bullaDao);
        assertEq(bullaDaoBalanceAfter - bullaDaoBalanceBefore, protocolFeeBalance, "BullaDao should receive the protocol fee");
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be 0 after withdrawal");
    }

    /// @notice Verify reconciliation doesn't double-count protocol fee
    function test_ReconciliationDoesNotDoubleCountProtocolFee() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create, approve, and fund invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 protocolFeeAfterFunding = bullaFactoring.protocolFeeBalance();

        // Pay invoice
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint256 protocolFeeAfterReconciliation = bullaFactoring.protocolFeeBalance();

        // Protocol fee should NOT increase at reconciliation since it was already realized at funding
        assertEq(protocolFeeAfterReconciliation, protocolFeeAfterFunding, "Protocol fee should not increase at reconciliation");
    }

    /// @notice Verify unfactoring doesn't double-count protocol fee
    function test_UnfactoringDoesNotDoubleCountProtocolFee() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create, approve, and fund invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 protocolFeeAfterFunding = bullaFactoring.protocolFeeBalance();

        // Unfactor invoice (original creditor unfactors)
        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), 1 ether);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();

        uint256 protocolFeeAfterUnfactor = bullaFactoring.protocolFeeBalance();

        // Protocol fee should NOT increase at unfactoring since it was already realized at funding
        assertEq(protocolFeeAfterUnfactor, protocolFeeAfterFunding, "Protocol fee should not increase at unfactoring");
    }

    /// @notice Verify capital account is unchanged after funding
    function test_CapitalAccountUnchangedAfterFunding() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Create, approve, and fund invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 capitalAccountAfter = bullaFactoring.calculateCapitalAccount();
        assertEq(capitalAccountAfter, capitalAccountBefore, "Capital account should not change after funding");
    }

    /// @notice Verify protocol-withdraw-then-unfactor edge case
    function test_ProtocolWithdrawThenUnfactor() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create, approve, and fund invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Protocol withdraws fees immediately
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be 0 after withdrawal");

        // Now unfactor — this should work fine, protocol fee should NOT be re-added
        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), 1 ether);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();

        // Protocol fee balance should still be 0 (not re-added during unfactor)
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee should not be re-added during unfactoring");
    }

    /// @notice Verify protocol-withdraw-then-reconcile edge case
    function test_ProtocolWithdrawThenReconcile() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create, approve, and fund invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.1 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Protocol withdraws fees immediately
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        // Pay invoice and reconcile
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Protocol fee balance should still be 0 (not re-added during reconciliation)
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee should not be re-added during reconciliation");
    }

    /// @notice Verify multiple invoices accumulate protocol fees at funding
    function test_MultipleInvoicesAccumulateProtocolFeesAtFunding() public {
        uint256 initialDeposit = 10 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 totalProtocolFees = 0;

        // Fund 3 invoices
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(bob);
            uint256 invoiceId = createClaim(bob, alice, 0.1 ether, dueBy);
            vm.stopPrank();

            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();

            uint256 feeBefore = bullaFactoring.protocolFeeBalance();

            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            vm.stopPrank();

            uint256 feeAfter = bullaFactoring.protocolFeeBalance();
            totalProtocolFees += feeAfter - feeBefore;
        }

        assertEq(bullaFactoring.protocolFeeBalance(), totalProtocolFees, "Total protocol fee should be sum of all individual fees");
        assertTrue(totalProtocolFees > 0, "Should have accumulated protocol fees");
    }
}
