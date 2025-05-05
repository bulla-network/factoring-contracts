// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimInvoiceProviderAdapterV2 } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
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
        vault.deposit(initialDeposit, alice);
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
        vault.deposit(initialDeposit, alice);
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
        vault.deposit(initialDeposit, alice);
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
        vault.deposit(initialDeposit, alice);
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
        vault.deposit(initialDeposit, alice);
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
        vault.deposit(initialDeposit, alice);
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
        asset.approve(address(vault), initialDepositAlice);
        vault.deposit(initialDepositAlice, alice);
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

        bullaFactoring.reconcileActivePaidInvoices();

        (uint256 kickbackAmount,,,)  = bullaFactoring.calculateKickbackAmount(invoiceId);
        uint256 sharesToRedeemIncludingKickback = vault.convertToShares(initialDepositAlice + kickbackAmount);
        uint maxRedeem = vault.unlockedShareSupply();

        assertGt(sharesToRedeemIncludingKickback, maxRedeem, "sharesToRedeemIncludingKickback should be greater than maxRedeem");

        // if Alice tries to redeem more shares than she owns, it will revert
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", alice, sharesToRedeemIncludingKickback, vault.balanceOf(alice)));
        vault.redeem(sharesToRedeemIncludingKickback, alice, alice);
        vm.stopPrank();
    }

    function testGainLossCanBeNegative() public {
        uint initialImpairReserve = 500; 
        asset.approve(address(bullaFactoring), initialImpairReserve);
        bullaFactoring.setImpairReserve(initialImpairReserve);

        // Alice deposits into the fund
        assertEq(vault.balanceOf(alice), 0, "Alice should have no funds");
        uint256 initialDepositAlice = 25000000000; // initialize a 25k pool
        vm.startPrank(alice);
        asset.approve(address(vault), initialDepositAlice);
        vault.deposit(initialDepositAlice, alice);
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

        uint initialPricePerShare = vault.previewRedeem(1e18);

        // due date is in 30 days, + 60 days grace period
        uint256 waitDaysToApplyImpairment = 100;
        vm.warp(block.timestamp + waitDaysToApplyImpairment * 1 days);

        // Alice never pays the invoices
        // fund owner impaires both invoices
        bullaFactoring.impairInvoice(invoiceId01);
        bullaFactoring.impairInvoice(invoiceId02);

        // Check that the capital account is not negative
        uint256 capitalAccount = vault.calculateCapitalAccount();
        assertGt(capitalAccount, 0);

        uint pricePerShareAfter = vault.previewRedeem(1e18);

        assertLt(pricePerShareAfter, initialPricePerShare, "Price per share should decline due to impairment");

        // alice withdraws her funds
        vm.startPrank(alice);
        uint assetWithdrawn = vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();

        // assert that alice withdraws less assets than she has put in
        assertLt(assetWithdrawn, initialDepositAlice, "Alice should withdraw less assets than she has put in");
    }

    function testImpairedInvoiceWithAllSharesRedeemed() public {
        uint initialImpairReserve = 500; 
        asset.approve(address(bullaFactoring), initialImpairReserve);
        bullaFactoring.setImpairReserve(initialImpairReserve);
        
        assertEq(vault.balanceOf(alice), 0, "Alice's balance should start at 0");

        uint256 initialDeposit = 1000000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceAmount = 100000;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
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

        uint256 maxRedeemAmountAfterGracePeriod = vault.unlockedShareSupply();

        // Fund impairs the invoice
        bullaFactoring.impairInvoice(invoiceId);

        uint256 maxRedeemAmountAfterGraceImpairment = vault.unlockedShareSupply();

        assertLt(maxRedeemAmountAfterGracePeriod, maxRedeemAmountAfterGraceImpairment, "maxRedeemAmountAfterGracePeriod should be lower than maxRedeemAmountAfterGraceImpairment as totalAssets get reduces when an impairment by fund happens due to it being removed from active invoices, and having the interest realised");

        bullaFactoring.reconcileActivePaidInvoices();

        // Alice redeems all her shares
        vm.prank(alice);
        uint redeemAmountFirst = vault.redeem(aliceShares, alice, alice);
        assertGt(initialDeposit, redeemAmountFirst, "Alice should be able to redeem less than what she initial deposited");
        vm.stopPrank();

        // Verify that Alice's share balance is now zero, as there are no other pending invoices to be paid
        assertEq(vault.balanceOf(alice), 0, "Alice's share balance should be zero");

        assertEq(vault.unlockedShareSupply(), 0, "maxRedeem should be zero");
        assertEq(vault.totalAssets(), 0, "totalAssets should be zero");
    }

    function testTargetAndRealisedFeeMatchIfPaidOnTime() public {
        dueBy = block.timestamp + 30 days;
        assertEq(dueBy, block.timestamp + minDays * 1 days);

        upfrontBps = 8000; // 80% of invoice amount factored

        uint256 initialDeposit = 1000000000000000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceAmount = 1000000000000;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        (, uint256 adminFee, uint256 targetInterest, uint256 targetProtocolFee,) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        uint capitalAccountBefore = vault.calculateCapitalAccount();

        // Simulate invoice is paid exactly on time
        vm.warp(dueBy - 1);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint availableAssetsAfter = vault.totalAssets();
        uint totalAssetsAfter = asset.balanceOf(address(bullaFactoring));

        uint targetFees = adminFee + targetInterest + targetProtocolFee;
        uint realizedFees = totalAssetsAfter - availableAssetsAfter;
        uint gainLoss = vault.calculateCapitalAccount() - capitalAccountBefore;
        assertEq(realizedFees + gainLoss, targetFees, "Realized fees + realised gains should match target fees when invoice is paid on time");
    }

    function testTotalAssetsDeclineWhenCapitalIsAtRisk() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 3000000; // deposit 3 USDC
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialPps = vault.previewRedeem(1e18);

        vm.startPrank(bob);
        uint invoiceId01Amount = 500000; // 0.5 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays first invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();
        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();

        uint ppsAfterFirstRepayment = vault.previewRedeem(1e18);

        assertGt(ppsAfterFirstRepayment, initialPps, "Price per share should increase after first repayment");

        vm.startPrank(bob);
        uint invoiceId02Amount = 1000000; // 1 USDC
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        uint priceBeforeRedeem = vault.previewRedeem(1e18);

        // alice maxRedeems
        uint amountToRedeem = vault.unlockedShareSupply();
        vm.prank(alice);
        vault.redeem(amountToRedeem, alice, alice);
        assertGt(vault.balanceOf(alice), 0, "Alice should have some balance left");
        vm.stopPrank();

        uint priceAfterRedeem = vault.previewRedeem(1e18);
        assertApproxEqAbs(priceBeforeRedeem, priceAfterRedeem, 1, "Price per share should remain the same after redemption");

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays second invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();

        uint ppsAfterSecondRepayment = vault.previewRedeem(1e18);
        assertGt(ppsAfterSecondRepayment, ppsAfterFirstRepayment, "Price per share should increase after second repayment");

        // alice maxRedeems
        amountToRedeem = vault.unlockedShareSupply();
        vm.prank(alice);
        vault.redeem(amountToRedeem, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();

        uint ppsAfterFullRedemption = vault.previewRedeem(1e18);
        assertEq(initialPps, ppsAfterFullRedemption, "Price per share should be equal to initial price per share");
    }

    function testConvertToSharesWithZeroSupply() public {
        // Ensure no deposits have been made
        assertEq(vault.totalSupply(), 0, "Total supply should be zero");
        uint256 assetsToConvert = 120922222;
        uint256 sharesConverted = vault.convertToShares(assetsToConvert);

        assertEq(sharesConverted, assetsToConvert, "Converted shares should equal assets when supply is zero");
    }

    function testUpfrontBpsFailsIf0or1000() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);

        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, 0, minDays);
        vm.stopPrank();

        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, 10001, minDays);
        vm.stopPrank();
    }

    function testOnlyUnderwriterCanApprove() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerNotUnderwriter()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(address(this));
        bullaFactoring.setUnderwriter(alice);
        vm.stopPrank();

        vm.startPrank(alice);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
    }

    function testUnderwriterCantBeAddressZero() public {
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        bullaFactoring.setUnderwriter(address(0));
        vm.stopPrank();
    }

    function testSetDepositPermissions() public {
        uint256 initialDeposit = 900;

        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(address(this));
        vault.setDepositPermissions(address(new MockPermissions()));
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", alice));
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testSetFactoringPermissions() public {
        uint256 invoiceAmount = 100000; // Invoice amount is $100000

        uint256 initialDeposit = 2000000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId1);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps);
        vm.stopPrank();

        vm.startPrank(address(this));
        bullaFactoring.setFactoringPermissions(address(new MockPermissions()));
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId2);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactoring(address)", bob));
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps);
        vm.stopPrank();
    }

    function testChangingFeesDoesNotAffectActiveInvoices() public {
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, targetYield, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // set new fees higher than initial fees
        bullaFactoring.setProtocolFeeBps(50);
        bullaFactoring.setAdminFeeBps(100);
        uint16 newTargetYield = 1400;
        bullaFactoring.setTargetYield(newTargetYield);

        // create another identical claim
        vm.startPrank(bob);
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, newTargetYield, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        (, uint targetAdminFeeAfterFeeChange, , uint targetProtocolFeeAfterFeeChange,) = bullaFactoring.calculateTargetFees(invoiceId02, upfrontBps);
        vm.stopPrank();

        vm.warp(dueBy - 1);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceId01Amount);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();
        assertLt(bullaFactoring.protocolFeeBalance(), targetProtocolFeeAfterFeeChange, "Protocol fee balance should be less than new protocol fee");
        assertLt(bullaFactoring.adminFeeBalance(), targetAdminFeeAfterFeeChange, "Admin fee balance should be less than new admin fee");
    }
}

