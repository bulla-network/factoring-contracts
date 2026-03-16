// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IBullaFactoringV2_2} from "../../contracts/interfaces/IBullaFactoring.sol";

contract TestBatchOperations is CommonSetup {

    // ============================================
    // Helpers
    // ============================================

    /// @dev Creates 3 invoices from bob (creditor) to alice (debtor) with default params
    function _create3Invoices(uint256 invoiceAmount) internal returns (uint256 id1, uint256 id2, uint256 id3) {
        vm.startPrank(bob);
        id1 = createClaim(bob, alice, invoiceAmount, dueBy);
        id2 = createClaim(bob, alice, invoiceAmount, dueBy);
        id3 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
    }

    /// @dev Batch-approves 3 invoices via the batch interface
    function _batchApprove3(uint256 id1, uint256 id2, uint256 id3) internal {
        IBullaFactoringV2_2.ApproveInvoiceParams[] memory params = new IBullaFactoringV2_2.ApproveInvoiceParams[](3);
        params[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: id1,
            targetYieldBps: targetYield,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            initialInvoiceValueOverride: 0
        });
        params[1] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: id2,
            targetYieldBps: targetYield,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            initialInvoiceValueOverride: 0
        });
        params[2] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: id3,
            targetYieldBps: targetYield,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            initialInvoiceValueOverride: 0
        });

        vm.prank(underwriter);
        bullaFactoring.approveInvoices(params);
    }

    /// @dev Batch-funds 3 invoices via the batch interface, all pointing to receiver index 0
    function _batchFund3(uint256 id1, uint256 id2, uint256 id3, address receiver) internal returns (uint256[] memory) {
        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](3);
        address[] memory receivers = new address[](1);
        receivers[0] = receiver;

        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id1,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });
        params[1] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id2,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });
        params[2] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id3,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), id1);
        bullaClaim.approve(address(bullaFactoring), id2);
        bullaClaim.approve(address(bullaFactoring), id3);
        uint256[] memory amounts = bullaFactoring.fundInvoices(params, receivers);
        vm.stopPrank();

        return amounts;
    }

    /// @dev Helper to check if an invoice is approved by trying to fund it and verifying calculateTargetFees succeeds
    function _isApproved(uint256 invoiceId) internal view returns (bool) {
        (bool approved, , , , , , , , , , , , , ) = bullaFactoring.approvedInvoices(invoiceId);
        return approved;
    }

    /// @dev Helper to get the initialInvoiceValue from the auto-generated getter
    function _getInitialInvoiceValue(uint256 invoiceId) internal view returns (uint256) {
        (, , , , , , , , uint256 initialInvoiceValue, , , , , ) = bullaFactoring.approvedInvoices(invoiceId);
        return initialInvoiceValue;
    }

    /// @dev Helper to get fundedAmountNet from the auto-generated getter
    function _getFundedAmountNet(uint256 invoiceId) internal view returns (uint256) {
        (, , , , , , , uint256 fundedAmountNet, , , , , , ) = bullaFactoring.approvedInvoices(invoiceId);
        return fundedAmountNet;
    }

    /// @dev Helper to get receiverAddress from the auto-generated getter
    function _getReceiverAddress(uint256 invoiceId) internal view returns (address) {
        (, , , , , , , , , , , address receiverAddress, , ) = bullaFactoring.approvedInvoices(invoiceId);
        return receiverAddress;
    }

    // ============================================
    // A. BATCH APPROVE TESTS
    // ============================================

    function test_approveInvoices_batchMultipleInvoices() public {
        uint256 invoiceAmount = 100000;
        (uint256 id1, uint256 id2, uint256 id3) = _create3Invoices(invoiceAmount);

        _batchApprove3(id1, id2, id3);

        // Verify all 3 invoices are approved
        assertTrue(_isApproved(id1), "Invoice 1 should be approved");
        assertTrue(_isApproved(id2), "Invoice 2 should be approved");
        assertTrue(_isApproved(id3), "Invoice 3 should be approved");

        // Verify initialInvoiceValue is set (no override, so it should be full invoice amount)
        assertEq(_getInitialInvoiceValue(id1), invoiceAmount, "Invoice 1 initial value");
        assertEq(_getInitialInvoiceValue(id2), invoiceAmount, "Invoice 2 initial value");
        assertEq(_getInitialInvoiceValue(id3), invoiceAmount, "Invoice 3 initial value");
    }

    function test_approveInvoices_singleItemBatch() public {
        uint256 invoiceAmount = 100000;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        IBullaFactoringV2_2.ApproveInvoiceParams[] memory params = new IBullaFactoringV2_2.ApproveInvoiceParams[](1);
        params[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: invoiceId,
            targetYieldBps: targetYield,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            initialInvoiceValueOverride: 0
        });

        vm.prank(underwriter);
        bullaFactoring.approveInvoices(params);

        assertTrue(_isApproved(invoiceId), "Single invoice should be approved");
        assertEq(_getInitialInvoiceValue(invoiceId), invoiceAmount, "Initial value matches invoice amount");
    }

    function test_approveInvoices_onlyUnderwriter() public {
        uint256 invoiceAmount = 100000;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        IBullaFactoringV2_2.ApproveInvoiceParams[] memory params = new IBullaFactoringV2_2.ApproveInvoiceParams[](1);
        params[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: invoiceId,
            targetYieldBps: targetYield,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            initialInvoiceValueOverride: 0
        });

        // alice is not the underwriter
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerNotUnderwriter()"));
        bullaFactoring.approveInvoices(params);
    }

    // ============================================
    // B. BATCH FUND TESTS
    // ============================================

    function test_fundInvoices_batchMultipleInvoices() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;
        (uint256 id1, uint256 id2, uint256 id3) = _create3Invoices(invoiceAmount);
        _batchApprove3(id1, id2, id3);

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        uint256[] memory fundedAmounts = _batchFund3(id1, id2, id3, address(0));

        // All 3 should return non-zero funded amounts
        assertGt(fundedAmounts[0], 0, "Invoice 1 funded amount > 0");
        assertGt(fundedAmounts[1], 0, "Invoice 2 funded amount > 0");
        assertGt(fundedAmounts[2], 0, "Invoice 3 funded amount > 0");

        // All 3 amounts should be the same (same invoice amount and params)
        assertEq(fundedAmounts[0], fundedAmounts[1], "Invoice 1 and 2 funded amounts should match");
        assertEq(fundedAmounts[1], fundedAmounts[2], "Invoice 2 and 3 funded amounts should match");

        // Verify all are now active
        uint256[] memory activeInvoices = bullaFactoring.getActiveInvoices();
        assertEq(activeInvoices.length, 3, "Should have 3 active invoices");

        // Verify bob received the total net funded amount (address(0) maps to msg.sender=bob)
        uint256 totalFunded = fundedAmounts[0] + fundedAmounts[1] + fundedAmounts[2];
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, totalFunded, "Bob should receive total net funded amount");

        // Verify funded amounts are stored in approvals
        assertGt(_getFundedAmountNet(id1), 0, "Approval 1 fundedAmountNet stored");
        assertGt(_getFundedAmountNet(id2), 0, "Approval 2 fundedAmountNet stored");
        assertGt(_getFundedAmountNet(id3), 0, "Approval 3 fundedAmountNet stored");
    }

    function test_fundInvoices_differentReceivers() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;
        (uint256 id1, uint256 id2, uint256 id3) = _create3Invoices(invoiceAmount);
        _batchApprove3(id1, id2, id3);

        // Set up 2 receiver addresses: charlie at index 0, alice at index 1
        address[] memory receivers = new address[](2);
        receivers[0] = charlie;
        receivers[1] = alice;

        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](3);
        // Invoice 1 -> receiver index 0 (charlie)
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id1,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });
        // Invoice 2 -> receiver index 1 (alice)
        params[1] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id2,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 1
        });
        // Invoice 3 -> receiver index 0 (charlie)
        params[2] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id3,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });

        uint256 charlieBalanceBefore = asset.balanceOf(charlie);
        uint256 aliceBalanceBefore = asset.balanceOf(alice);

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), id1);
        bullaClaim.approve(address(bullaFactoring), id2);
        bullaClaim.approve(address(bullaFactoring), id3);
        uint256[] memory fundedAmounts = bullaFactoring.fundInvoices(params, receivers);
        vm.stopPrank();

        // charlie receives invoice 1 + invoice 3
        uint256 expectedCharlieReceived = fundedAmounts[0] + fundedAmounts[2];
        assertEq(asset.balanceOf(charlie) - charlieBalanceBefore, expectedCharlieReceived, "Charlie should receive funds for invoices 1 and 3");

        // alice receives invoice 2
        uint256 expectedAliceReceived = fundedAmounts[1];
        assertEq(asset.balanceOf(alice) - aliceBalanceBefore, expectedAliceReceived, "Alice should receive funds for invoice 2");

        // Verify receiver addresses are recorded in approvals
        assertEq(_getReceiverAddress(id1), charlie, "Invoice 1 receiver should be charlie");
        assertEq(_getReceiverAddress(id2), alice, "Invoice 2 receiver should be alice");
        assertEq(_getReceiverAddress(id3), charlie, "Invoice 3 receiver should be charlie");
    }

    function test_fundInvoices_addressZeroReceiver() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        vm.prank(underwriter);
        _approveInvoice(invoiceId, targetYield, spreadBps, upfrontBps, 0);

        // Use address(0) in the receiver addresses array
        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        address[] memory receivers = new address[](1);
        receivers[0] = address(0);
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: invoiceId,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256[] memory amounts = bullaFactoring.fundInvoices(params, receivers);
        vm.stopPrank();

        // address(0) maps to msg.sender (bob), so bob should receive the funds
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, amounts[0], "address(0) receiver should route funds to msg.sender (bob)");

        // Verify the stored receiver is resolved to bob (msg.sender)
        assertEq(_getReceiverAddress(invoiceId), bob, "Stored receiver should be bob (resolved from address(0))");
    }

    function test_fundInvoices_singleItemBatch() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        vm.prank(underwriter);
        _approveInvoice(invoiceId, targetYield, spreadBps, upfrontBps, 0);

        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        address[] memory receivers = new address[](1);
        receivers[0] = address(0);
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: invoiceId,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256[] memory amounts = bullaFactoring.fundInvoices(params, receivers);
        vm.stopPrank();

        assertEq(amounts.length, 1, "Should return exactly 1 funded amount");
        assertGt(amounts[0], 0, "Funded amount should be > 0");

        // Verify the invoice is now active
        assertEq(bullaFactoring.getActiveInvoicesCount(), 1, "Should have 1 active invoice");
    }

    function test_fundInvoices_invalidReceiverAddressIndex() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        vm.prank(underwriter);
        _approveInvoice(invoiceId, targetYield, spreadBps, upfrontBps, 0);

        // receiverAddresses has 1 element (index 0), but we reference index 1
        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        address[] memory receivers = new address[](1);
        receivers[0] = address(0);
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: invoiceId,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 1  // out of bounds
        });

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.expectRevert(abi.encodeWithSignature("InvalidReceiverAddressIndex()"));
        bullaFactoring.fundInvoices(params, receivers);
        vm.stopPrank();
    }

    function test_fundInvoices_insufficientLiquidity() public {
        // Deposit only 50000 but try to fund 3 invoices of 100000 each (needs ~300000)
        uint256 depositAmount = 50000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;
        (uint256 id1, uint256 id2, uint256 id3) = _create3Invoices(invoiceAmount);
        _batchApprove3(id1, id2, id3);

        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](3);
        address[] memory receivers = new address[](1);
        receivers[0] = address(0);

        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id1,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });
        params[1] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id2,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });
        params[2] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: id3,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), id1);
        bullaClaim.approve(address(bullaFactoring), id2);
        bullaClaim.approve(address(bullaFactoring), id3);
        vm.expectRevert(); // InsufficientFunds(available, required)
        bullaFactoring.fundInvoices(params, receivers);
        vm.stopPrank();
    }
}
