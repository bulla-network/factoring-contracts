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
import "@bulla-network/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";

import { CommonSetup } from './CommonSetup.t.sol';


contract TestErrorHandlingAndEdgeCases is CommonSetup {
   function testUnknownInvoiceId() public {
        uint invoiceId01Amount = 100;
        createClaim(bob, alice, invoiceId01Amount, dueBy);
        // picking a random number as incorrect invoice id
        uint256 incorrectInvoiceId = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % 10000000000;
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InexistentInvoice()"));
        bullaFactoring.approveInvoice(incorrectInvoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
    }

   function testFundInvoiceWithoutUnderwriterApproval() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotApproved()"));
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();
    }

    function testFundInvoiceExpiredApproval() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("ApprovalExpired()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();
    }

    function testInvoiceCancelled() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.rescindClaim(invoiceId);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId02 = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(alice);
        bullaClaim.rejectClaim(invoiceId02);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();
    }

   function testInvoicePaid() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoicePaidAmountChanged()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();
    }

    function testCreditorChanged() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.transferFrom(bob, alice, invoiceId);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCreditorChanged()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();
    }

    function testAprCapWhenPastDueDate() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays the first invoice
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint256 dueByNew = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId03Amount = 100;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueByNew);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 900 days to simulate interest rate cap
        vm.warp(block.timestamp + 900 days);

        uint balanceBefore = asset.balanceOf(bob);
        // alice pays the second invoice
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId03, invoiceId03Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();
        uint balanceAfter = asset.balanceOf(bob);

        assertTrue(balanceBefore == balanceAfter, "No kickback as interest rate cap has been reached");
    }

    function testCannotRedeemKickbackAmount() public {
        // Alice deposits into the fund
        uint256 initialDepositAlice = 100;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDepositAlice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Bob funds an invoice
        uint invoiceIdAmount = 100; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Alice pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceIdAmount);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        (uint256 kickbackAmount,,,)  = bullaFactoring.calculateKickbackAmount(invoiceId);
        uint256 sharesToRedeemIncludingKickback = bullaFactoring.convertToShares(initialDepositAlice + kickbackAmount);
        uint maxRedeem = bullaFactoring.maxRedeem();

        assertTrue(sharesToRedeemIncludingKickback > maxRedeem);

        uint pricePerShare = bullaFactoring.pricePerShare();
        uint maxRedeemAmount = maxRedeem * pricePerShare / bullaFactoring.SCALING_FACTOR();

        // if Alice tries to redeem more shares than she owns, she'll be capped by max redeem amount
        vm.startPrank(alice);
        uint balanceBefore = asset.balanceOf(alice);
        bullaFactoring.redeem(sharesToRedeemIncludingKickback, alice, alice);
        uint balanceAfter = asset.balanceOf(alice);
        vm.stopPrank();

        uint actualAssetsRedeems = balanceAfter - balanceBefore;

        assertEq(actualAssetsRedeems, maxRedeemAmount, "Redeem amount should be capped to max redeem amount");
    }

    function testGainLossCanBeNegative() public {
        // Alice deposits into the fund
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no funds");
        uint256 initialDepositAlice = 25000000000; // initialize a 25k pool
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDepositAlice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        uint invoiceAmount = 5000000000; // 5k invoice

        // Bob funds the first invoice
        uint256 invoiceId01 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Bob funds the second invoice 5k second invoice
        uint256 invoiceId02 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        uint initialPricePerShare = bullaFactoring.pricePerShare();

        // due date is in 30 days, + 60 days grace period
        uint256 waitDaysToApplyImpairment = 100;
        vm.warp(block.timestamp + waitDaysToApplyImpairment * 1 days);

        // Alice never pays the invoices
        // fund owner impaires both invoices
        bullaFactoring.impairInvoice(invoiceId01);
        bullaFactoring.impairInvoice(invoiceId02);

        // Check that the realized gain/loss is negative
        int256 realizedGainLoss = bullaFactoring.calculateRealizedGainLoss();
        assertLt(realizedGainLoss, 0);

        // Check that the capital account is not negative
        uint256 capitalAccount = bullaFactoring.calculateCapitalAccount();
        assertGt(capitalAccount, 0);

        uint pricePerShareAfter = bullaFactoring.pricePerShare();

        assertLt(pricePerShareAfter, initialPricePerShare, "Price per share should decline due to impairment");

        // alice withdraws her funds
        vm.startPrank(alice);
        uint assetWithdrawn = bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        // assert that alice withdraws less assets than she has put in
        assertLt(assetWithdrawn, initialDepositAlice, "Alice should withdraw less assets than she has put in");
    }

    function testImpairedInvoiceWithAllSharesRedeemed() public {
        uint256 initialDeposit = 1000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, 100000, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Simulate the invoice becoming impaired after the grace period
        uint256 gracePeriodDays = bullaFactoring.gracePeriodDays();
        vm.warp(dueBy + gracePeriodDays * 1 days + 1);

        uint256 maxRedeemAmountAfterGracePeriod = bullaFactoring.maxRedeem();

        // Fund impairs the invoice
        bullaFactoring.impairInvoice(invoiceId);

        uint256 maxRedeemAmountAfterGraceImpairment = bullaFactoring.maxRedeem();

        assertEq(maxRedeemAmountAfterGracePeriod, maxRedeemAmountAfterGraceImpairment, "maxRedeemAmountAfterGracePeriod should equal maxRedeemAmountAfterGraceImpairment");

        // assert that the max redeem amount after grace period is less than the initial max redeem amount
        assertLt(maxRedeemAmountAfterGraceImpairment, bullaFactoring.balanceOf(alice), "Alice's share balance should not be zero");

        // Alice redeems all her shares
        vm.prank(alice);
        bullaFactoring.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        uint aliceBalanceAfter = bullaFactoring.balanceOf(alice);

        // Verify that Alice's share balance is not zero, as the max redeem amount is less than her balance
        assertGt(bullaFactoring.balanceOf(alice), 0, "Alice's share balance should not be zero");

        uint256 fundBalanceBefore = bullaFactoring.availableAssets();

        // Simulate the debtor paying the impaired invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 100000);
        bullaClaim.payClaim(invoiceId, 100000);
        vm.stopPrank();

        // Reconcile the paid invoices
        bullaFactoring.reconcileActivePaidInvoices();

        uint256 fundBalanceAfter = bullaFactoring.availableAssets();

        // Verify that the fund's balance has increased
        assertGt(fundBalanceAfter, fundBalanceBefore, "The fund's balance should be greater than when there was impairment");

        uint256 maxRedeemAmountAfterRepayment = bullaFactoring.maxRedeem();
        assertGt(maxRedeemAmountAfterRepayment, 0, "The max redeem amount now should be greater than zero");

        // Alice redeems all her remaining shares
        vm.prank(alice);
        bullaFactoring.redeem(aliceBalanceAfter, alice, alice);
        vm.stopPrank();

        uint256 fundBalanceEnd = bullaFactoring.availableAssets();

        assertEq(fundBalanceEnd, 0, "The fund's balance should be zero once everything is withdrawn");
    }
}

