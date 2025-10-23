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
import {CreateClaimParams, ClaimBinding} from "bulla-contracts-v2/src/types/Types.sol";
import { CommonSetup } from './CommonSetup.t.sol';

contract TestInvoiceFundingAndPayment is CommonSetup {
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);

    function testInvoicePaymentAndKickbackCalculation() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();


        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();
    
        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should increased due to redeemed invoices");
    }

    function testImmediateRepaymentStillChangesPrice() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();


        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();
    
        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should change even if invoice repaid immediately");
    }

    function testFactorerUsesLowerUpfrontBps() public {
        uint256 invoiceAmount = 100000; 
        uint16 approvedUpfrontBps = 8000; 
        uint16 factorerUpfrontBps = 7000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the 2 invoices
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice with approvedUpfrontBps
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, approvedUpfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, approvedUpfrontBps, minDays, 0);
        vm.stopPrank();

        // Factorer funds one invoice at a lower UpfrontBps
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, approvedUpfrontBps, address(0));
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId2, factorerUpfrontBps, address(0));
        vm.stopPrank();

        (, , , , , , , uint256 actualFundedAmount, , , , , ) = bullaFactoring.approvedInvoices(invoiceId);
        (, , , , , , , uint256 actualFundedAmountLowerUpfrontBps, , , , , ) = bullaFactoring.approvedInvoices(invoiceId2);

        assertTrue(actualFundedAmount > actualFundedAmountLowerUpfrontBps, "Funded amounts should reflect the actual upfront bps chosen by the factorer" );
    }

    function testMinDaysInterest() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        dueBy = block.timestamp + 7 days;
        minDays = 30;

        vm.startPrank(bob);
        uint invoiceId01Amount = 100000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        (, , uint targetInterest01, , , ) = bullaFactoring.calculateTargetFees(invoiceId01, upfrontBps);
        vm.stopPrank();

        dueBy = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId02Amount = 100000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        (, , uint targetInterest02, , , ) = bullaFactoring.calculateTargetFees(invoiceId02, upfrontBps);
        vm.stopPrank();

        assertEq(targetInterest02, targetInterest01, "Target interest should be the same for both invoices as min days for interest to be charged is 30 days");

        uint capitalAccountAfterInvoice0 = bullaFactoring.calculateCapitalAccount();

        // alice pays both invoices, at different times
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        // Simulate debtor paying in 1 days
        vm.warp(block.timestamp + 1 days);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);

        bullaFactoring.reconcileActivePaidInvoices();
        
        uint capitalAccountAfterInvoice1 = bullaFactoring.calculateCapitalAccount();

        // Simulate debtor paying second invoice in 30 days
        vm.warp(block.timestamp + 28 days);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();
        
        uint capitalAccountAfterInvoice2 = bullaFactoring.calculateCapitalAccount();

        assertEq(capitalAccountAfterInvoice2 - capitalAccountAfterInvoice1, capitalAccountAfterInvoice1 - capitalAccountAfterInvoice0, "Factoring gain should be the same for both invoices as min days for interest to be charged is 30 days");
    }

    function testDisperseKickbackAmount() public {
        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialFactorerBalance = asset.balanceOf(bob);

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);

        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // alice pays both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        // automation will signal that we have some paid invoices
        (uint256[] memory paidInvoices, , , ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 1);

        // Calculate expected kickback amount before reconciliation
        (uint256 expectedKickbackAmount,,,) = bullaFactoring.calculateKickbackAmount(invoiceId01);
        
        // Expect InvoiceKickbackAmountSent event if kickback amount > 0
        if (expectedKickbackAmount > 0) {
            vm.expectEmit(true, true, true, true);
            emit InvoiceKickbackAmountSent(invoiceId01, expectedKickbackAmount, bob);
        }

        // owner will reconcile paid invoices to account for any realized gains or losses
        bullaFactoring.reconcileActivePaidInvoices();

        // Check if the kickback and funded amount were correctly transferred
        (, , , , , , , , uint256 fundedAmountNet, , , , ) = bullaFactoring.approvedInvoices(invoiceId01);
        (uint256 kickbackAmount,,,)  = bullaFactoring.calculateKickbackAmount(invoiceId01);

        uint256 finalBalanceOwner = asset.balanceOf(address(bob));

        assertEq(finalBalanceOwner, initialFactorerBalance + kickbackAmount + fundedAmountNet, "Kickback amount was not dispersed correctly");
    }

    function testZeroKickbackAmount() public {
        // 100% upfront bps to simulate TCS
        upfrontBps = 10000;
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();


        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);

        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        uint256 actualDaysUntilPayment = 60;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();


        uint balanceBeforeReconciliation = asset.balanceOf(bob);

        bullaFactoring.reconcileActivePaidInvoices();

        (uint256 kickbackAmount,,,) = bullaFactoring.calculateKickbackAmount(invoiceId01);

        uint balanceAfterReconciliation = asset.balanceOf(bob);

        assertEq(kickbackAmount, 0, "Kickback amount should be 0");
        assertEq(balanceBeforeReconciliation, balanceAfterReconciliation, "Kickback amount should be 0");
    }

    function testFundInvoiceWithPartiallyAndFullyPaidInvoices() public {
        uint256 invoiceAmount = 100000;
        uint256 initialPaidAmount = 50000; // 50% of the invoice amount is already paid
        uint16 upfrontBps = 8000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates two invoices
        vm.startPrank(bob);
        uint256 partiallyPaidInvoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 fullyUnpaidInvoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Simulate partial payment of the first invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), initialPaidAmount);
        bullaClaim.payClaim(partiallyPaidInvoiceId, initialPaidAmount);
        vm.stopPrank();

        // Underwriter approves both invoices
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(partiallyPaidInvoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(fullyUnpaidInvoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Factorer funds both invoices
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), partiallyPaidInvoiceId);
        uint256 partiallyPaidFundedAmount = bullaFactoring.fundInvoice(partiallyPaidInvoiceId, upfrontBps, address(0));
        bullaClaim.approve(address(bullaFactoring), fullyUnpaidInvoiceId);
        uint256 fullyUnpaidFundedAmount =bullaFactoring.fundInvoice(fullyUnpaidInvoiceId, upfrontBps, address(0));
        vm.stopPrank();

        assertTrue(fullyUnpaidFundedAmount > partiallyPaidFundedAmount, "Funded amount for partially paid invoice should be less than fully unpaid invoice");
        assertApproxEqAbs((fullyUnpaidFundedAmount / 2), partiallyPaidFundedAmount, 1, "Funded amount for partially paid invoice should be half than fully unpaid invoice");
    }

    function testPartiallyPaidInvoice() public {
        upfrontBps = 8000;
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId01Amount, dueBy);


        // alice pays half of the first outstanding invoice
        vm.startPrank(alice);
        uint initialPayment = invoiceId01Amount / 2;
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, initialPayment);
        vm.stopPrank();


        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId02, targetYield, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        uint fundedAmount01 = bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        uint fundedAmount02 = bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        vm.stopPrank();

        assertLt(fundedAmount01, fundedAmount02, "Funded amount for partially paid invoice should be less than fully unpaid invoice");

        // Simulate debtor paying on time
        vm.warp(dueBy - 1);

        (uint256 kickbackAmount01,,,) = bullaFactoring.calculateKickbackAmount(invoiceId01);
        (uint256 kickbackAmount02,,,) = bullaFactoring.calculateKickbackAmount(invoiceId02);
        assertLt(kickbackAmount01, kickbackAmount02, "Kickback amount for partially paid invoice should be less than kickback amount for fully unpaid invoice");
    }

    function testFullyPaidInvoice() public {
        upfrontBps = 8000;
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);


        // alice pays half of the first outstanding invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceId01Amount);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();


        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCannotBePaid()"));
        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
    }

    function testSetApprovalDuration() public {
        upfrontBps = 8000;
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.stopPrank();

        vm.startPrank(address(this));
        bullaFactoring.setApprovalDuration(0); // 1 minute 
        vm.stopPrank();


        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 minutes);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("ApprovalExpired()"));
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testOnlyCreditorCanFundInvoice() public {
        // 100% upfront bps to simulate TCS
        upfrontBps = 10000;
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // alice is allowed to factor
        factoringPermissions.allow(alice);

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);

        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert();
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testOnlyFactoringPossibleWithSameToken() public {
        // 100% upfront bps to simulate TCS
        upfrontBps = 10000;
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // alice is allowed to factor
        factoringPermissions.allow(alice);

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000; // 1 USDC

        CreateClaimParams memory params = CreateClaimParams({
            creditor: bob,
            debtor: alice,
            claimAmount: invoiceId01Amount,
            dueBy: dueBy,
            description: "",
            token: address(bullaFactoring),
            binding: ClaimBinding.Unbound,
            impairmentGracePeriod: 15 days
        });

        // create claim with different token than one in pool
        uint256 invoiceId01 = bullaClaim.createClaim(params);

        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceTokenMismatch()"));
        bullaFactoring.approveInvoice(invoiceId01, targetYield, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
    }

    function testProtocolFeeIndependentOfInterestRate() public {
        uint256 initialDeposit = 5000000; // 5 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 1000000; // 1 USDC
        upfrontBps = 8000; // 80% upfront

        // Create two identical invoices
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve first invoice with 10% APR
        uint16 highInterestApr = 1000; // 10% APR
        uint16 highSpreadBps = 1000; // 10% spread
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, highInterestApr, highSpreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Approve second invoice with 0% APR and 0% spread
        uint16 zeroInterestApr = 0; // 0% APR
        uint16 zeroSpreadBps = 0; // 0% spread
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, zeroInterestApr, zeroSpreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Calculate target fees for both invoices
        (, uint256 adminFee1, uint256 targetInterest1, uint256 targetSpread1, uint256 targetProtocolFee1, ) = bullaFactoring.calculateTargetFees(invoiceId1, upfrontBps);
        (, uint256 adminFee2, uint256 targetInterest2, uint256 targetSpread2, uint256 targetProtocolFee2, ) = bullaFactoring.calculateTargetFees(invoiceId2, upfrontBps);

        // Protocol fee should be the same regardless of interest rate
        assertApproxEqAbs(targetProtocolFee1, targetProtocolFee2, 1, "Protocol fee should be the same whether interest rate is 10% or 0%");
        
        // Admin fee should also be the same (independent of interest rate)
        assertEq(adminFee1, adminFee2, "Admin fee should be the same regardless of interest rate");
        
        // Interest should be different
        assertTrue(targetInterest1 > targetInterest2, "Interest should be higher for 10% APR than 0% APR");
        assertEq(targetInterest2, 0, "Interest should be 0 for 0% APR");

        // Spread should be different
        assertTrue(targetSpread1 > targetSpread2, "Spread should be higher for 10% spread than 0% spread");
        assertEq(targetSpread2, 0, "Spread should be 0 for 0% spread");

        // Fund both invoices
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate payment after some time
        vm.warp(block.timestamp + 30 days);

        // Pay both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount * 2);
        bullaClaim.payClaim(invoiceId1, invoiceAmount);
        bullaClaim.payClaim(invoiceId2, invoiceAmount);
        vm.stopPrank();

        // Get actual realized fees
        (,uint256 realizedInterest1, uint256 realizedSpread1, uint256 realizedAdminFee1) = bullaFactoring.calculateKickbackAmount(invoiceId1);
        (,uint256 realizedInterest2, uint256 realizedSpread2, uint256 realizedAdminFee2) = bullaFactoring.calculateKickbackAmount(invoiceId2);

        // Protocol fees are now taken upfront at funding time, so no longer part of the kickback calculation
        
        // Realized admin fees should be the same
        assertEq(realizedAdminFee1, realizedAdminFee2, "Realized admin fee should be the same regardless of interest rate");
        
        // Realized interest should be different
        assertTrue(realizedInterest1 > realizedInterest2, "Realized interest should be higher for 10% APR than 0% APR");
        assertEq(realizedInterest2, 0, "Realized interest should be 0 for 0% APR");

        // Realized spread should be different
        assertTrue(realizedSpread1 > realizedSpread2, "Realized spread should be higher for 10% spread than 0% spread");
        assertEq(realizedSpread2, 0, "Realized spread should be 0 for 0% spread");
    }

    function testDepositAndRedeemPermissionsAreDifferent() public {
        address depositor = makeAddr("depositor");
        address redeemer = makeAddr("redeemer");
        uint256 depositAmount = 100000;

        // Give both users some tokens
        vm.startPrank(address(this));
        asset.mint(depositor, depositAmount);
        vm.stopPrank();

        // Initially, both users should not have any permissions
        vm.startPrank(depositor);
        asset.approve(address(bullaFactoring), depositAmount);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", depositor));
        bullaFactoring.deposit(depositAmount, depositor);
        vm.stopPrank();

        vm.startPrank(redeemer);
        asset.approve(address(bullaFactoring), depositAmount);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", redeemer));
        bullaFactoring.deposit(depositAmount, redeemer);
        vm.stopPrank();

        // Grant only deposit permission to depositor
        vm.startPrank(address(this));
        depositPermissions.allow(depositor);
        vm.stopPrank();

        // Grant only redeem permission to redeemer
        vm.startPrank(address(this));
        redeemPermissions.allow(redeemer);
        vm.stopPrank();

        // Depositor should be able to deposit but not redeem
        vm.startPrank(depositor);
        uint256 shares = bullaFactoring.deposit(depositAmount, depositor);
        assertTrue(shares > 0, "Depositor should receive shares");
        
        // Depositor should not be able to redeem (no redeem permission)
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", depositor));
        bullaFactoring.redeem(shares, depositor, depositor);
        vm.stopPrank();

        // Redeemer should not be able to deposit (no deposit permission)
        vm.startPrank(redeemer);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", redeemer));
        bullaFactoring.deposit(depositAmount, redeemer);
        vm.stopPrank();

        // Transfer shares from depositor to redeemer to test redemption
        vm.startPrank(depositor);
        bullaFactoring.transfer(redeemer, shares);
        vm.stopPrank();

        // Redeemer should be able to redeem the transferred shares
        vm.startPrank(redeemer);
        uint256 redeemedAssets = bullaFactoring.redeem(shares, redeemer, redeemer);
        assertTrue(redeemedAssets > 0, "Redeemer should receive assets from redemption");
        vm.stopPrank();

        assertEq(asset.balanceOf(redeemer), depositAmount, "Redeemer should receive the deposited amount back");
    }

    function testCanChangeDepositAndRedeemPermissionsIndependently() public {
        address user = makeAddr("user");
        uint256 depositAmount = 100000;

        // Give user some tokens
        vm.startPrank(address(this));
        asset.mint(user, depositAmount * 2);
        vm.stopPrank();

        // Create new permission contracts
        MockPermissions newDepositPermissions = new MockPermissions();
        MockPermissions newRedeemPermissions = new MockPermissions();

        // Allow user in new deposit permissions only
        newDepositPermissions.allow(user);

        // Update only deposit permissions
        vm.startPrank(address(this));
        bullaFactoring.setDepositPermissions(address(newDepositPermissions));
        vm.stopPrank();

        // User should be able to deposit with new permissions
        vm.startPrank(user);
        asset.approve(address(bullaFactoring), depositAmount);
        uint256 shares = bullaFactoring.deposit(depositAmount, user);
        assertTrue(shares > 0, "User should be able to deposit with new deposit permissions");

        // User should not be able to redeem (still using old redeem permissions where user is not allowed)
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", user));
        bullaFactoring.redeem(shares, user, user);
        vm.stopPrank();

        // Allow user in new redeem permissions
        newRedeemPermissions.allow(user);

        // Update only redeem permissions
        vm.startPrank(address(this));
        bullaFactoring.setRedeemPermissions(address(newRedeemPermissions));
        vm.stopPrank();

        // Now user should be able to redeem
        vm.startPrank(user);
        uint256 redeemedAssets = bullaFactoring.redeem(shares, user, user);
        assertTrue(redeemedAssets > 0, "User should be able to redeem with new redeem permissions");
        vm.stopPrank();

        // Revoke user from new deposit permissions
        newDepositPermissions.disallow(user);

        // User should not be able to deposit anymore
        vm.startPrank(user);
        asset.approve(address(bullaFactoring), depositAmount);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", user));
        bullaFactoring.deposit(depositAmount, user);
        vm.stopPrank();
    }

    function testDepositPermissionsDoNotAffectRedemption() public {
        address user = makeAddr("user");
        uint256 depositAmount = 100000;

        // Give user some tokens and allow both deposit and redeem initially
        vm.startPrank(address(this));
        asset.mint(user, depositAmount);
        depositPermissions.allow(user);
        redeemPermissions.allow(user);
        vm.stopPrank();

        // User deposits
        vm.startPrank(user);
        asset.approve(address(bullaFactoring), depositAmount);
        uint256 shares = bullaFactoring.deposit(depositAmount, user);
        vm.stopPrank();

        // Remove user from deposit permissions
        vm.startPrank(address(this));
        depositPermissions.disallow(user);
        vm.stopPrank();

        // User should still be able to redeem even without deposit permissions
        vm.startPrank(user);
        uint256 redeemedAssets = bullaFactoring.redeem(shares, user, user);
        assertTrue(redeemedAssets > 0, "User should be able to redeem even without deposit permissions");
        vm.stopPrank();

        assertEq(asset.balanceOf(user), depositAmount, "User should receive full deposit amount back");
    }

    function testRedeemPermissionsDoNotAffectDeposit() public {
        address user = makeAddr("user");
        uint256 depositAmount = 100000;

        // Give user some tokens and allow both deposit and redeem initially
        vm.startPrank(address(this));
        asset.mint(user, depositAmount * 2);
        depositPermissions.allow(user);
        redeemPermissions.allow(user);
        vm.stopPrank();

        // User deposits first time
        vm.startPrank(user);
        asset.approve(address(bullaFactoring), depositAmount);
        uint256 shares1 = bullaFactoring.deposit(depositAmount, user);
        vm.stopPrank();

        // Remove user from redeem permissions
        vm.startPrank(address(this));
        redeemPermissions.disallow(user);
        vm.stopPrank();

        // User should still be able to deposit even without redeem permissions
        vm.startPrank(user);
        asset.approve(address(bullaFactoring), depositAmount);
        uint256 shares2 = bullaFactoring.deposit(depositAmount, user);
        assertTrue(shares2 > 0, "User should be able to deposit even without redeem permissions");
        vm.stopPrank();

        // But user should not be able to redeem
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", user));
        bullaFactoring.redeem(shares1 + shares2, user, user);
        vm.stopPrank();
    }

    function testFundInvoiceWithSpecificReceiver() public {
        uint256 invoiceAmount = 100000;
        upfrontBps = 8000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Check initial balances
        uint256 bobInitialBalance = asset.balanceOf(bob);
        uint256 charlieInitialBalance = asset.balanceOf(charlie);

        // Fund invoice with charlie as receiver
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, charlie);
        vm.stopPrank();

        // Verify charlie received the funds, not bob
        assertEq(asset.balanceOf(bob), bobInitialBalance, "Bob should not have received any funds");
        assertEq(asset.balanceOf(charlie), charlieInitialBalance + fundedAmount, "Charlie should have received the funded amount");
    }

    function testFundInvoiceWithZeroAddressReceiver() public {
        uint256 invoiceAmount = 100000;
        upfrontBps = 8000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Check initial balance
        uint256 bobInitialBalance = asset.balanceOf(bob);

        // Fund invoice with address(0) as receiver (should default to msg.sender)
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Verify bob received the funds (since address(0) defaults to msg.sender)
        assertEq(asset.balanceOf(bob), bobInitialBalance + fundedAmount, "Bob should have received the funded amount when receiver is address(0)");
    }

    function testFundInvoiceReceiverConsistency() public {
        uint256 invoiceAmount = 100000;
        upfrontBps = 8000;

        uint256 initialDeposit = 400000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create two identical invoices
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve both invoices
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Check initial balances
        uint256 bobInitialBalance = asset.balanceOf(bob);
        uint256 charlieInitialBalance = asset.balanceOf(charlie);

        // Fund first invoice with address(0) (should go to bob)
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        uint256 fundedAmount1 = bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        
        // Fund second invoice with charlie as receiver
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        uint256 fundedAmount2 = bullaFactoring.fundInvoice(invoiceId2, upfrontBps, charlie);
        vm.stopPrank();

        // Verify the funded amounts are the same (since invoices are identical)
        assertEq(fundedAmount1, fundedAmount2, "Funded amounts should be identical for identical invoices");

        // Verify balances
        assertEq(asset.balanceOf(bob), bobInitialBalance + fundedAmount1, "Bob should have received funds from first invoice");
        assertEq(asset.balanceOf(charlie), charlieInitialBalance + fundedAmount2, "Charlie should have received funds from second invoice");
    }

    function testKickbackGoesToCorrectReceiver() public {
        uint256 invoiceAmount = 100000;
        upfrontBps = 8000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Check initial balances
        uint256 charlieInitialBalance = asset.balanceOf(charlie);

        // Fund invoice with charlie as receiver
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, charlie);
        vm.stopPrank();

        // Verify charlie received the initial funding
        assertEq(asset.balanceOf(charlie), charlieInitialBalance + fundedAmount, "Charlie should have received the funded amount");

        // Simulate time passing for interest accrual
        vm.warp(block.timestamp + 30 days);

        uint256 bobBalanceBeforePayment = asset.balanceOf(bob);
        uint256 charlieBalanceBeforePayment = asset.balanceOf(charlie);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Calculate expected kickback amount
        (uint256 expectedKickback,,,) = bullaFactoring.calculateKickbackAmount(invoiceId);

        // Reconcile to trigger kickback payment
        bullaFactoring.reconcileActivePaidInvoices();

        // Verify kickback went to charlie (the receiver), not bob (the original creditor)
        assertEq(asset.balanceOf(bob), bobBalanceBeforePayment, "Bob should not have received any kickback");
        assertEq(asset.balanceOf(charlie), charlieBalanceBeforePayment + expectedKickback, "Charlie should have received the kickback amount");
    }

    function testKickbackGoesToMsgSenderWhenReceiverIsZero() public {
        uint256 invoiceAmount = 100000;
        upfrontBps = 8000;

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Record initial balance
        uint256 bobInitialBalance = asset.balanceOf(bob);

        // Fund invoice with address(0) as receiver (should default to msg.sender = bob)
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Verify bob received the initial funding
        assertEq(asset.balanceOf(bob), bobInitialBalance + fundedAmount, "Bob should have received the funded amount");

        // Simulate time passing for interest accrual
        vm.warp(block.timestamp + 30 days);

        // Record balance before payment
        uint256 bobBalanceBeforePayment = asset.balanceOf(bob);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Calculate expected kickback amount
        (uint256 expectedKickback,,,) = bullaFactoring.calculateKickbackAmount(invoiceId);

        // Reconcile to trigger kickback payment
        bullaFactoring.reconcileActivePaidInvoices();

        // Verify kickback went to bob (msg.sender when receiver was address(0))
        assertEq(asset.balanceOf(bob), bobBalanceBeforePayment + expectedKickback, "Bob should have received the kickback amount when receiver was address(0)");
    }
}
