// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';

contract TestPreviewUnfactor is CommonSetup {
    error InvoiceAlreadyPaid();

    function testPreviewUnfactorRefundMatchesActualUnfactor() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 1000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        uint invoiceAmount = 100;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Alice makes a large partial payment (95 out of 100) to create a refund scenario
        uint256 partialPayment = 95;
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, partialPayment);
        vm.stopPrank();

        // Preview unfactor - should show negative amount (refund/kickback to creditor)
        int256 previewAmount = bullaFactoring.previewUnfactor(invoiceId);
        assertTrue(previewAmount < 0, "Preview should show negative amount (refund to creditor)");
        
        // Now actually unfactor and verify the amounts match
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        vm.prank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Bob should have received a refund equal to the absolute value of the preview
        uint256 refundReceived = bobBalanceAfter - bobBalanceBefore;
        assertEq(int256(refundReceived), -previewAmount, "Actual refund should match preview amount");
    }

    function testPreviewUnfactorPaymentRequiresApproval() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 1000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        uint invoiceAmount = 100;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward to accrue some interest
        vm.warp(block.timestamp + 30 days);

        // Preview unfactor - should show positive amount (Bob owes the pool)
        int256 previewAmount = bullaFactoring.previewUnfactor(invoiceId);
        assertTrue(previewAmount > 0, "Preview should show positive amount (creditor owes pool)");
        
        // Ensure Bob has no prior approval
        vm.prank(bob);
        asset.approve(address(bullaFactoring), 0);
        
        // Try to unfactor without sufficient approval - should fail with ERC20InsufficientAllowance
        vm.prank(bob);
        vm.expectRevert();
        bullaFactoring.unfactorInvoice(invoiceId);
        
        // Now approve the exact amount from preview and unfactor successfully
        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), uint256(previewAmount));
        
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        vm.stopPrank();
        
        // Verify Bob paid the expected amount
        uint256 amountPaid = bobBalanceBefore - bobBalanceAfter;
        assertEq(int256(amountPaid), previewAmount, "Amount paid should match preview");
        
        // Verify the NFT was transferred back to Bob
        assertEq(bullaClaim.ownerOf(invoiceId), bob, "Invoice NFT should be returned to Bob");
    }

    function testPreviewUnfactorPaidInvoiceReverts() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 1000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        uint invoiceAmount = 100;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Alice pays the invoice in full
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Preview unfactor on a paid invoice should revert
        vm.expectRevert(InvoiceAlreadyPaid.selector);
        bullaFactoring.previewUnfactor(invoiceId);
    }

    function testOriginalCreditorCanUnfactorAtAnytime() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 1000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        uint invoiceAmount = 100;
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward only 5 days - NOT past impairment (30 days due + 60 days grace = 90 days)
        vm.warp(block.timestamp + 5 days);

        // Preview unfactor - Bob should be able to preview even before impairment
        int256 previewAmount = bullaFactoring.previewUnfactor(invoiceId);
        assertTrue(previewAmount > 0, "Preview should show Bob owes the pool");

        // Bob (original creditor) should be able to unfactor BEFORE impairment date
        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), uint256(previewAmount));
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();

        // Verify the invoice NFT was returned to Bob
        assertEq(bullaClaim.ownerOf(invoiceId), bob, "Invoice NFT should be returned to Bob");
    }
}

