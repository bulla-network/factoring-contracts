// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimInvoiceProviderAdapter } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import { DAOMock } from 'contracts/mocks/DAOMock.sol';
import { TestSafe } from 'contracts/mocks/gnosisSafe.sol';
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";

import { CommonSetup } from './CommonSetup.t.sol';


contract TestFeesAndTax is CommonSetup {
    function testWithdrawFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.01 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Check initial balances
        uint256 initialBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 initialOwnerBalance = asset.balanceOf(address(this));



        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        // Check final balances
        uint256 finalBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 finalOwnerBalance = asset.balanceOf(address(this));

        // Check that the Bulla DAO and the owner's balances have increased by the expected fee amounts
        assertTrue(finalBullaDaoBalance > initialBullaDaoBalance, "Bulla DAO should receive protocol fees");
        assertTrue(finalOwnerBalance > initialOwnerBalance, "Owner should receive admin fees");
    }

    function testFeesDeductionFromCapitalAccount() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 90000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // owner will reconcile paid invoices to account for any realized gains or losses, and fees
        bullaFactoring.reconcileActivePaidInvoices();

        uint capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        uint capitalAccountAfter = bullaFactoring.calculateCapitalAccount();

        assertEq(capitalAccountAfter, capitalAccountBefore - adminFeeBalanceBefore - protocolFeeBalanceBefore, "Fees are should be deducted from capital account");
    }

    function testTaxAccrualAndWithdraw() public {
        dueBy = block.timestamp + 60 days; 
        uint256 invoiceAmount = 1000000000; 
        interestApr = 1000; 
        upfrontBps = 8000; 

        uint256 initialDeposit = 20 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();


        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 60;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint taxAmountBefore = bullaFactoring.taxBalance();
    
        assertTrue(taxAmountBefore > 0, "Tax accrues on invoice payment");

        // Retrieve the tax amount paid for the specific invoice
        uint256 expectedTaxAmount = bullaFactoring.paidInvoiceTax(invoiceId);
        assertEq(taxAmountBefore, expectedTaxAmount, "Tax amount matches the expected value");

        // owner withdraws tax
        bullaFactoring.withdrawTaxBalance();
        uint taxAmountAfter = bullaFactoring.taxBalance();

        assertEq(taxAmountAfter, 0, "Tax balance should be 0 after withdrawal");

        // cannot call when tax balance is 0
        vm.expectRevert(abi.encodeWithSignature("NoTaxBalanceToWithdraw()"));
        bullaFactoring.withdrawTaxBalance();
    }
}