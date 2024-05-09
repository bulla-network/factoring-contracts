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


contract TestInvoiceFundingAndPayment is CommonSetup {
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();


        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

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
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

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
        bullaFactoring.approveInvoice(invoiceId, interestApr, approvedUpfrontBps, minDays);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, approvedUpfrontBps, minDays);
        vm.stopPrank();

        // Factorer funds one invoice at a lower UpfrontBps
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, approvedUpfrontBps);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId2, factorerUpfrontBps);
        vm.stopPrank();

        uint256 actualFundedAmount = bullaFactoring.getFundedAmount(invoiceId);
        uint256 actualFundedAmountLowerUpfrontBps = bullaFactoring.getFundedAmount(invoiceId2);

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
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        (, , uint targetInterest01, ,) = bullaFactoring.calculateTargetFees(invoiceId01, upfrontBps);
        vm.stopPrank();

        dueBy = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId02Amount = 100000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        (, , uint targetInterest02, ,) = bullaFactoring.calculateTargetFees(invoiceId02, upfrontBps);
        vm.stopPrank();

        assertEq(targetInterest02, targetInterest01, "Target interest should be the same for both invoices as min days for interest to be charged is 30 days");

        // alice pays both invoices, at different times
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        // Simulate debtor paying in 1 days
        vm.warp(block.timestamp + 1 days);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        // Simulate debtor paying second invoice in 30 days
        vm.warp(block.timestamp + 30 days);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint factoringGain01 = bullaFactoring.paidInvoicesGain(invoiceId01);
        uint factoringGain02 = bullaFactoring.paidInvoicesGain(invoiceId02);

        assertEq(factoringGain01, factoringGain02, "Factoring gain should be the same for both invoices as min days for interest to be charged is 30 days");
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

        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        uint256 fundedTimestamp = block.timestamp;
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
        (uint256[] memory paidInvoices, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 1);

        // owner will reconcile paid invoices to account for any realized gains or losses
        bullaFactoring.reconcileActivePaidInvoices();

        // Check if the kickback and funded amount were correctly transferred
        uint256 fundedAmount = bullaFactoring.getFundedAmount(invoiceId01);
        uint256 kickbackAmount = calculateKickbackAmount(invoiceId01, fundedTimestamp, interestApr, fundedAmount);

        uint256 finalBalanceOwner = asset.balanceOf(address(bob));

        assertEq(finalBalanceOwner, initialFactorerBalance + kickbackAmount + fundedAmount, "Kickback amount was not dispersed correctly");
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

        bullaFactoring.approveInvoice(invoiceId01, targetYield, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        uint kickbackAmount = bullaFactoring.calculateKickbackAmount(invoiceId01);

        uint balanceBeforeReconciliation = asset.balanceOf(bob);

        bullaFactoring.reconcileActivePaidInvoices();

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
        bullaFactoring.approveInvoice(partiallyPaidInvoiceId, interestApr, upfrontBps, minDays);
        bullaFactoring.approveInvoice(fullyUnpaidInvoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // Factorer funds both invoices
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), partiallyPaidInvoiceId);
        uint256 partiallyPaidFundedAmount = bullaFactoring.fundInvoice(partiallyPaidInvoiceId, upfrontBps);
        bullaClaimERC721.approve(address(bullaFactoring), fullyUnpaidInvoiceId);
        uint256 fullyUnpaidFundedAmount =bullaFactoring.fundInvoice(fullyUnpaidInvoiceId, upfrontBps);
        vm.stopPrank();

        assertTrue(fullyUnpaidFundedAmount > partiallyPaidFundedAmount, "Funded amount for partially paid invoice should be less than fully unpaid invoice");
        assertApproxEqAbs((fullyUnpaidFundedAmount / 2), partiallyPaidFundedAmount, 1, "Funded amount for partially paid invoice should be half than fully unpaid invoice");
    }

}