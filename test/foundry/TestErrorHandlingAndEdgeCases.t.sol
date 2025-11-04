// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimV2InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol';
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
    event InvoiceApproved(uint256 indexed invoiceId, uint256 validUntil, IBullaFactoringV2.FeeParams feeParams);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor, uint256 dueDate, uint16 upfrontBps);
    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event InvoicePaid(uint256 indexed invoiceId, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee, uint256 fundedAmountNet, uint256 kickbackAmount, address indexed originalCreditor);
    event DepositPermissionsChanged(address newAddress);
    event FactoringPermissionsChanged(address newAddress);

   function testUnknownInvoiceId() public {
        uint invoiceId01Amount = 100;
        vm.prank(bob);
        createClaim(bob, alice, invoiceId01Amount, dueBy);
        // picking a random number as incorrect invoice id
        uint256 incorrectInvoiceId = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % 10000000000;
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("NotMinted()"));
        bullaFactoring.approveInvoice(incorrectInvoiceId, interestApr, spreadBps, upfrontBps, 0);
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
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotApproved()"));
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
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
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("ApprovalExpired()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
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
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.cancelClaim(invoiceId, "");
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId02 = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        bullaClaim.cancelClaim(invoiceId02, "");
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCanceled()"));
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
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
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoicePaidAmountChanged()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
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
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.transferFrom(bob, alice, invoiceId);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCreditorChanged()"));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
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
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays the first invoice
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        

        uint256 dueByNew = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId03Amount = 100;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueByNew);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps, address(0));
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
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Alice pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceIdAmount);
        
        // Test InvoicePaid event emission
        vm.expectEmit(true, true, false, false);
        emit InvoicePaid(invoiceId, 0, 0, 0, 0, 0, bob);

        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();

        (uint256 kickbackAmount,,,)  = bullaFactoring.calculateKickbackAmount(invoiceId);
        uint256 sharesToRedeemIncludingKickback = bullaFactoring.convertToShares(initialDepositAlice + kickbackAmount);
        uint maxRedeem = bullaFactoring.maxRedeem();

        assertGt(sharesToRedeemIncludingKickback, maxRedeem, "sharesToRedeemIncludingKickback should be greater than maxRedeem");

        // if Alice tries to redeem more shares than she owns, it will revert
        vm.recordLogs();
        vm.startPrank(alice);
        bullaFactoring.redeem(sharesToRedeemIncludingKickback, alice, alice);
        vm.stopPrank();

        (uint256 queuedShares, ) = getQueuedSharesAndAssetsFromEvent();
        
        assertGt(queuedShares, 0, "Should queue excess shares");
    }

    function testTargetAndRealisedFeeMatchIfPaidOnTime() public {
        dueBy = block.timestamp + 30 days;

        upfrontBps = 8000; // 80% of invoice amount factored

        uint256 initialDeposit = 1000000000000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceAmount = 1000000000000;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        (, uint256 adminFee, uint256 targetInterest, uint256 targetSpread, uint256 targetProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Simulate invoice is paid exactly on time
        vm.warp(dueBy);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint availableAssetsAfter = bullaFactoring.totalAssets();
        uint totalAssetsAfter = asset.balanceOf(address(bullaFactoring));

        // Protocol fees are collected upfront during funding, not as part of realized gains
        uint targetFees = adminFee + targetInterest + targetSpread + targetProtocolFee;
        uint realizedFees = totalAssetsAfter - availableAssetsAfter;
        uint gainLoss = bullaFactoring.calculateCapitalAccount() - capitalAccountBefore;

        assertEq(realizedFees + gainLoss, targetFees, "Realized fees + realised gains should match target fees when invoice is paid on time");
    }

    function testTotalAssetsDeclineWhenCapitalIsAtRisk() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 3000000; // deposit 3 USDC
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialPps = bullaFactoring.pricePerShare();

        vm.startPrank(bob);
        uint invoiceId01Amount = 500000; // 0.5 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays first invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        uint ppsAfterFirstRepayment = bullaFactoring.pricePerShare();

        assertGt(ppsAfterFirstRepayment, initialPps, "Price per share should increase after first repayment");

        vm.startPrank(bob);
        uint invoiceId02Amount = 1000000; // 1 USDC
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        vm.stopPrank();

        uint priceBeforeRedeem = bullaFactoring.pricePerShare();

        // alice maxRedeems
        uint amountToRedeem = bullaFactoring.maxRedeem();
        vm.prank(alice);
        bullaFactoring.redeem(amountToRedeem, alice, alice);
        assertGt(bullaFactoring.balanceOf(alice), 0, "Alice should have some balance left");
        vm.stopPrank();

        uint priceAfterRedeem = bullaFactoring.pricePerShare();
        assertApproxEqAbs(priceBeforeRedeem, priceAfterRedeem, 1, "Price per share should remain the same after redemption");

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 60 days);

        // alice pays second invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        uint ppsAfterSecondRepayment = bullaFactoring.pricePerShare();
        assertGt(ppsAfterSecondRepayment, ppsAfterFirstRepayment, "Price per share should increase after second repayment");

        // alice maxRedeems
        amountToRedeem = bullaFactoring.maxRedeem();
        vm.prank(alice);
        bullaFactoring.redeem(amountToRedeem, alice, alice);
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();

        uint ppsAfterFullRedemption = bullaFactoring.pricePerShare();
        assertEq(initialPps, ppsAfterFullRedemption, "Price per share should be equal to initial price per share");
    }

    function testConvertToSharesWithZeroSupply() public view {
        // Ensure no deposits have been made
        assertEq(bullaFactoring.totalSupply(), 0, "Total supply should be zero");
        uint256 assetsToConvert = 120922222;
        uint256 sharesConverted = bullaFactoring.convertToShares(assetsToConvert);

        assertEq(sharesConverted, assetsToConvert, "Converted shares should equal assets when supply is zero");
    }

    function testUpfrontBpsFailsIf0or1000() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);

        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, 0, 0);
        vm.stopPrank();

        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, 10001, 0);
        vm.stopPrank();
    }

    function testOnlyUnderwriterCanApprove() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerNotUnderwriter()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(address(this));
        bullaFactoring.setUnderwriter(alice);
        vm.stopPrank();

        vm.startPrank(alice);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
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
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(address(this));
        MockPermissions newPermissions = new MockPermissions();
        vm.expectEmit(true, true, true, true);
        emit DepositPermissionsChanged(address(newPermissions));
        bullaFactoring.setDepositPermissions(address(newPermissions));
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", alice));
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();
    }

    function testSetFactoringPermissions() public {
        uint256 invoiceAmount = 100000; // Invoice amount is $100000

        uint256 initialDeposit = 2000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(address(this));
        MockPermissions newFactoringPermissions = new MockPermissions();
        vm.expectEmit(true, true, true, true);
        emit FactoringPermissionsChanged(address(newFactoringPermissions));
        bullaFactoring.setFactoringPermissions(address(newFactoringPermissions));
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactoring(address)", bob));
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testChangingFeesDoesNotAffectActiveInvoices() public {
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
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
        bullaFactoring.approveInvoice(invoiceId02, newTargetYield, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        (, uint targetAdminFeeAfterFeeChange, , uint targetSpreadAfterFeeChange, uint targetProtocolFeeAfterFeeChange, ) = bullaFactoring.calculateTargetFees(invoiceId02, upfrontBps);
        vm.stopPrank();

        vm.warp(dueBy - 1);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceId01Amount);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        
        
        // Protocol fees are now collected upfront during funding, so we expect the sum of both invoices' protocol fees
        // First invoice: 2500 (old 25 bps rate), Second invoice: 5000 (new 50 bps rate)
        uint256 expectedProtocolFeeBalance = 2500 + targetProtocolFeeAfterFeeChange; // 2500 + 5000 = 7500
        assertEq(bullaFactoring.protocolFeeBalance(), expectedProtocolFeeBalance, "Protocol fee balance should equal sum of both invoices' upfront protocol fees");
        
        // Admin fees are still collected during reconciliation, so only the paid invoice should contribute
        uint256 targetCombinedAdminFeeAfterFeeChange = targetAdminFeeAfterFeeChange + targetSpreadAfterFeeChange;
        assertLt(bullaFactoring.adminFeeBalance(), targetCombinedAdminFeeAfterFeeChange, "Admin fee balance should be less than new combined admin+spread fee");
    }
}

