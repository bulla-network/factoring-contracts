// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "contracts/interfaces/IBullaFactoring.sol";
import {CreateClaimApprovalType} from '@bulla/contracts-v2/src/types/Types.sol';
import {EIP712Helper} from './utils/EIP712Helper.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TestLoanPaymentWorkflow
 * @notice Tests for loan payment scenarios with comprehensive balance checks
 * @dev All fees (targetYieldBps, spreadBps, protocolFeeBps, adminFeeBps) are ANNUALIZED rates
 *      Interest calculations are prorated based on actual loan duration: Interest = Principal × (Rate/10000) × (Days/365)
 */
contract TestLoanPaymentWorkflow is CommonSetup {

    EIP712Helper public sigHelper;
    
    event InvoicePaid(
        uint256 indexed invoiceId,
        uint256 trueInterest,
        uint256 trueSpreadAmount,
        uint256 trueAdminFee,
        uint256 fundedAmountNet,
        uint256 kickbackAmount,
        address indexed receiverAddress
    );
    
    event InvoiceKickbackAmountSent(
        uint256 indexed invoiceId,
        uint256 kickbackAmount,
        address indexed originalCreditor
    );

    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));
        
        // Add factoring pool to feeExemption whitelist
        feeExemptionWhitelist.allow(address(bullaFactoring));

        // Set up approval for mock controller to create many claims
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: bob,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max, // Max approvals
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: bobPK,
                user: bob,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
        
        // Set up approval for charlie as well
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: charlie,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: charliePK,
                user: charlie,
                controller: address(bullaFrendLend),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
    }
    
    // Helper function to create and fund a loan
    function createAndFundLoan(
        address debtor,
        uint256 principalAmount,
        uint16 targetYieldBps,
        uint16 spreadBps,
        uint256 termLength
    ) internal returns (uint256 loanId, uint256 loanOfferId) {
        // Alice deposits to fund the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(principalAmount * 2, alice);
        vm.stopPrank();
        
        // Underwriter offers loan
        vm.startPrank(underwriter);
        loanOfferId = bullaFactoring.offerLoan(
            debtor,
            targetYieldBps,
            spreadBps,
            principalAmount,
            termLength,
            365, // numberOfPeriodsPerYear
            "Test loan"
        );
        vm.stopPrank();
        
        // Debtor accepts loan
        vm.prank(debtor);
        loanId = bullaFrendLend.acceptLoan(loanOfferId);
        
        return (loanId, loanOfferId);
    }

    // ============= FULL PAYMENT TESTS =============
    
    function testLoanPayment_FullPaymentOnTime() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 1000; // 10% APR (annualized)
        uint16 spreadBps = 500; // 5% APR (annualized)  
        uint256 termLength = 30 days;
        
        (uint256 loanId, ) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward to loan due date
        vm.warp(block.timestamp + termLength);
        
        // Get loan details to calculate total amount due
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalAmountDue = remainingPrincipal + interest;
        
        // Record balances before payment
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();
        
        // Bob pays the loan in full
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), totalAmountDue);
        bullaFrendLend.payLoan(loanId, totalAmountDue);
        vm.stopPrank();
        
        // Record balances after payment and reconciliation
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalanceAfter = bullaFactoring.adminFeeBalance();
        
        // Verify payment went through
        assertEq(
            bobBalanceBefore - bobBalanceAfter,
            totalAmountDue,
            "Bob should have paid the total amount due"
        );
        
        // Verify factoring contract received the payment
        assertGt(
            factoringBalanceAfter,
            factoringBalanceBefore,
            "Factoring contract should have received payment"
        );
        
        // Verify fee balances increased
        // Note: Loan offers do not generate protocol fees - only admin fees apply
        assertEq(
            protocolFeeBalanceAfter,
            protocolFeeBalanceBefore,
            "Protocol fees do not apply to loan offers"
        );
        assertGt(
            adminFeeBalanceAfter,
            adminFeeBalanceBefore,
            "Admin fee balance should have increased"
        );
        
        // Verify loan is marked as paid
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(invoice.isPaid, "Loan should be marked as paid");
        
        // Verify kickback was sent to factoring contract (original creditor)
        assertGt(
            bullaFactoring.paidInvoicesGain(),
            0,
            "Should have recorded gain for paid loan"
        );
    }
    
    function testLoanPayment_FullPaymentEarly() public {
        uint256 principalAmount = 200_000;
        uint16 targetYieldBps = 1200; // 12% APR (annualized)
        uint16 spreadBps = 600; // 6% APR (annualized)
        uint256 termLength = 60 days;
        
        (uint256 loanId, ) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward to half the term (early payment)
        vm.warp(block.timestamp + (termLength / 2));
        
        // Get loan details
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalAmountDue = remainingPrincipal + interest;
        
        // Record balances before payment
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(); // Record cumulative gain before payment
        
        // Bob pays the loan early
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), totalAmountDue);
        bullaFrendLend.payLoan(loanId, totalAmountDue);
        vm.stopPrank();
        
        // Record balances after payment
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        
        // Verify payment
        assertEq(
            bobBalanceBefore - bobBalanceAfter,
            totalAmountDue,
            "Bob should have paid the amount due at payment time"
        );
        
        // Early payment should result in lower interest charges than full term
        // Calculate expected interest for half the term (annualized rates)
        // Note: paidInvoicesGain now only tracks the target yield portion (not spread)
        uint256 actualDays = termLength / 2 / 1 days; // 30 days for early payment
        uint256 fullTermDays = termLength / 1 days; // 60 days for full term
        uint256 expectedEarlyInterest = Math.mulDiv(
            Math.mulDiv(principalAmount, targetYieldBps, 10000),
            actualDays,
            365
        );
        uint256 expectedFullTermInterest = Math.mulDiv(
            Math.mulDiv(principalAmount, targetYieldBps, 10000),
            fullTermDays,
            365
        );
        uint256 gainAfter = bullaFactoring.paidInvoicesGain();
        uint256 actualInterest = gainAfter - gainBefore; // Calculate gain from this payment
        
        assertLt(
            actualInterest,
            expectedFullTermInterest,
            "Early payment should result in lower interest than full term"
        );
        
        // Allow for some variance due to time-based calculations but should be close to expected
        assertApproxEqRel(
            actualInterest,
            expectedEarlyInterest,
            0.05e18, // 5% tolerance
            "Early payment interest should match expected annualized amount"
        );
        
        // Verify loan is paid
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(invoice.isPaid, "Loan should be marked as paid");
    }
    
    function testLoanPayment_FullPaymentLate() public {
        uint256 principalAmount = 150_000;
        uint16 targetYieldBps = 800; // 8% APR (annualized)
        uint16 spreadBps = 400; // 4% APR (annualized)
        uint256 termLength = 45 days;
        
        (uint256 loanId, uint256 loanOfferId) = createAndFundLoan(
            charlie,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward past the due date (late payment)
        vm.warp(block.timestamp + termLength + 15 days);
        
        // Get loan details
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalAmountDue = remainingPrincipal + interest;
        
        // Record balances before payment
        uint256 charlieBalanceBefore = asset.balanceOf(charlie);
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(); // Record cumulative gain before payment
        
        // Charlie pays the loan late
        vm.startPrank(charlie);
        asset.approve(address(bullaFrendLend), totalAmountDue);
        bullaFrendLend.payLoan(loanId, totalAmountDue);
        vm.stopPrank();
        
        // Record balances after payment
        uint256 charlieBalanceAfter = asset.balanceOf(charlie);
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        
        // Verify payment
        assertEq(
            charlieBalanceBefore - charlieBalanceAfter,
            totalAmountDue,
            "Charlie should have paid the total amount due including late fees"
        );
        
        // Late payment should include additional interest
        // Calculate expected interest for the basic term (45 days) and late term (45 + 15 = 60 days) - annualized
        // Note: paidInvoicesGain now only tracks the target yield portion (not spread)
        uint256 basicTermDays = termLength / 1 days; // 45 days
        uint256 lateTermDays = (termLength + 15 days) / 1 days; // 60 days
        uint256 expectedBasicTermInterest = Math.mulDiv(
            Math.mulDiv(principalAmount, targetYieldBps, 10000),
            basicTermDays,
            365
        );
        uint256 expectedLateTermInterest = Math.mulDiv(
            Math.mulDiv(principalAmount, targetYieldBps, 10000),
            lateTermDays,
            365
        );
        uint256 gainAfter = bullaFactoring.paidInvoicesGain();
        uint256 actualInterest = gainAfter - gainBefore; // Calculate gain from this payment
        
        assertGt(
            actualInterest,
            expectedBasicTermInterest,
            "Late payment should result in higher interest than basic term"
        );
        
        // Late payment should be close to expected annualized amount for extended term
        assertApproxEqRel(
            actualInterest,
            expectedLateTermInterest,
            0.05e18, // 5% tolerance
            "Late payment interest should match expected annualized amount for extended term"
        );
        
        // Verify loan is paid
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(invoice.isPaid, "Loan should be marked as paid");
    }

    // ============= PARTIAL PAYMENT TESTS =============
    
    function testLoanPayment_PartialPaymentFollowedByFull() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 1000; // 10% APR (annualized)
        uint16 spreadBps = 500; // 5% APR (annualized)
        uint256 termLength = 30 days;
        
        (uint256 loanId, uint256 loanOfferId) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward to mid-term
        vm.warp(block.timestamp + (termLength / 2));
        
        // Make partial payment (50% of principal)
        uint256 partialPaymentAmount = principalAmount / 2;
        
        // Record balances before partial payment
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), partialPaymentAmount);
        bullaFrendLend.payLoan(loanId, partialPaymentAmount);
        vm.stopPrank();
        
        // Record balances after partial payment
        uint256 bobBalanceAfterPartial = asset.balanceOf(bob);
        uint256 factoringBalanceAfterPartial = asset.balanceOf(address(bullaFactoring));
        
        // Verify partial payment
        assertEq(
            bobBalanceBefore - bobBalanceAfterPartial,
            partialPaymentAmount,
            "Bob should have made partial payment"
        );
        
        // Loan should not be marked as paid yet
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterPartial = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertFalse(invoiceAfterPartial.isPaid, "Loan should not be marked as paid after partial payment");
        
        // Fast forward to due date
        vm.warp(block.timestamp + (termLength / 2));
        
        // Get remaining amount due
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 remainingAmountDue = remainingPrincipal + interest;
        
        // Make final payment
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), remainingAmountDue);
        bullaFrendLend.payLoan(loanId, remainingAmountDue);
        vm.stopPrank();
        
        // Record final balances
        uint256 bobBalanceFinal = asset.balanceOf(bob);
        uint256 factoringBalanceFinal = asset.balanceOf(address(bullaFactoring));
        
        // Verify final payment
        assertEq(
            bobBalanceAfterPartial - bobBalanceFinal,
            remainingAmountDue,
            "Bob should have paid remaining amount"
        );
        
        // Verify loan is now paid
        IInvoiceProviderAdapterV2.Invoice memory invoiceFinal = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(invoiceFinal.isPaid, "Loan should be marked as paid after full payment");
        
        // Verify total payment equals expected amount
        uint256 totalPaid = partialPaymentAmount + remainingAmountDue;
        assertGt(totalPaid, principalAmount, "Total payment should exceed principal due to interest");
    }

    // ============= MULTIPLE LOANS PAYMENT TESTS =============
    
    function testLoanPayment_MultipleLoansDifferentPaymentTiming() public {
        uint256 principalAmount = 50_000;
        uint16 targetYieldBps = 1000;
        uint16 spreadBps = 500;
        uint256 termLength = 30 days;
        
        // Create and fund multiple loans
        (uint256 loanId1,) = createAndFundLoan(bob, principalAmount, targetYieldBps, spreadBps, termLength);
        (uint256 loanId2,) = createAndFundLoan(charlie, principalAmount, targetYieldBps, spreadBps, termLength);
        (uint256 loanId3,) = createAndFundLoan(bob, principalAmount, targetYieldBps, spreadBps, termLength);
        
        // Record initial balances
        uint256 bobBalanceInitial = asset.balanceOf(bob);
        uint256 charlieBalanceInitial = asset.balanceOf(charlie);
        uint256 factoringBalanceInitial = asset.balanceOf(address(bullaFactoring));

        uint256 remainingPrincipal;
        uint256 interest;
        
        // Fast forward to mid-term and pay loan 1 early
        vm.warp(block.timestamp + (termLength / 2));
        (remainingPrincipal, interest) = bullaFrendLend.getTotalAmountDue(loanId1);
        uint256 loan1AmountDue = remainingPrincipal + interest;
        
        uint256 gainBeforeLoan1 = bullaFactoring.paidInvoicesGain();
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), loan1AmountDue);
        bullaFrendLend.payLoan(loanId1, loan1AmountDue);
        vm.stopPrank();

        uint256 gainAfterLoan1 = bullaFactoring.paidInvoicesGain();
        
        // Fast forward to due date and pay loan 2 on time
        vm.warp(block.timestamp + (termLength / 2));
        (remainingPrincipal, interest) = bullaFrendLend.getTotalAmountDue(loanId2);
        uint256 loan2AmountDue = remainingPrincipal + interest;
        
        vm.startPrank(charlie);
        asset.approve(address(bullaFrendLend), loan2AmountDue);
        bullaFrendLend.payLoan(loanId2, loan2AmountDue);
        vm.stopPrank();

        uint256 gainAfterLoan2 = bullaFactoring.paidInvoicesGain();
        
        // Fast forward past due date and pay loan 3 late
        vm.warp(block.timestamp + 10 days);
        (remainingPrincipal, interest) = bullaFrendLend.getTotalAmountDue(loanId3);
        uint256 loan3AmountDue = remainingPrincipal + interest;
        
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), loan3AmountDue);
        bullaFrendLend.payLoan(loanId3, loan3AmountDue);
        vm.stopPrank();

        uint256 gainAfterLoan3 = bullaFactoring.paidInvoicesGain();
        
        // Record final balances
        uint256 bobBalanceFinal = asset.balanceOf(bob);
        uint256 charlieBalanceFinal = asset.balanceOf(charlie);
        uint256 factoringBalanceFinal = asset.balanceOf(address(bullaFactoring));
        
        // Verify all payments were made
        uint256 bobTotalPaid = bobBalanceInitial - bobBalanceFinal;
        uint256 charlieTotalPaid = charlieBalanceInitial - charlieBalanceFinal;
        
        assertEq(bobTotalPaid, loan1AmountDue + loan3AmountDue, "Bob should have paid for both his loans");
        assertEq(charlieTotalPaid, loan2AmountDue, "Charlie should have paid for his loan");
        
        // Verify all loans are marked as paid
        IInvoiceProviderAdapterV2.Invoice memory invoice1 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId1);
        IInvoiceProviderAdapterV2.Invoice memory invoice2 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId2);
        IInvoiceProviderAdapterV2.Invoice memory invoice3 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId3);
        
        assertTrue(invoice1.isPaid, "Loan 1 should be paid");
        assertTrue(invoice2.isPaid, "Loan 2 should be paid");
        assertTrue(invoice3.isPaid, "Loan 3 should be paid");
        
        // Verify gains increased with each payment and that late payments contribute to total gains
        assertGt(gainAfterLoan1, gainBeforeLoan1, "Loan 1 payment should contribute to gains");
        assertGt(gainAfterLoan2, gainAfterLoan1, "Loan 2 payment should increase total gains");
        assertGt(gainAfterLoan3, gainAfterLoan2, "Loan 3 payment should further increase total gains");
        
        // Calculate individual loan gains
        uint256 loan1Interest = gainAfterLoan1 - gainBeforeLoan1;
        uint256 loan3Interest = gainAfterLoan3 - gainAfterLoan2;
        
        assertGt(loan3Interest, loan1Interest, "Late payment should have higher interest than early payment");
        
        // Verify approximate expected interests based on payment timing (annualized)
        // Note: paidInvoicesGain now only tracks the target yield portion (not spread)
        // Loan 1: paid after 15 days (termLength/2)
        uint256 loan1Days = (termLength / 2) / 1 days; // 15 days
        uint256 expectedLoan1Interest = Math.mulDiv(
            Math.mulDiv(principalAmount, targetYieldBps, 10000),
            loan1Days,
            365
        );
        
        // Loan 3: paid after 40 days (termLength + 10 days late)
        uint256 loan3Days = (termLength + 10 days) / 1 days; // 40 days  
        uint256 expectedLoan3Interest = Math.mulDiv(
            Math.mulDiv(principalAmount, targetYieldBps, 10000),
            loan3Days,
            365
        );
        
        // Allow for some variance due to time-based calculations
        assertApproxEqRel(loan1Interest, expectedLoan1Interest, 0.1e18, "Loan 1 interest should match expected annualized amount");
        assertApproxEqRel(loan3Interest, expectedLoan3Interest, 0.1e18, "Loan 3 interest should match expected annualized amount");
    }

    // ============= EVENT EMISSION TESTS =============
    
    function testLoanPayment_EventEmission() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 1000;
        uint16 spreadBps = 500;
        uint256 termLength = 30 days;
        
        (uint256 loanId, uint256 loanOfferId) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward to due date
        vm.warp(block.timestamp + termLength);
        
        // Pay loan
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalAmountDue = remainingPrincipal + interest;
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), totalAmountDue);
        
        // Expect events during reconciliation
        // Note: Since this is a loan payment, we need to expect the actual calculated fees
        vm.expectEmit(true, false, false, false);
        emit InvoicePaid(loanId, 0, 0, 0, principalAmount, 0, address(bullaFactoring));

        bullaFrendLend.payLoan(loanId, totalAmountDue);
        vm.stopPrank();
        
    }

    // ============= BALANCE RECONCILIATION TESTS =============
    
    function testLoanPayment_BalanceReconciliation() public {
        uint256 principalAmount = 200_000;
        uint16 targetYieldBps = 1500; // 15% APR (annualized)
        uint16 spreadBps = 750; // 7.5% APR (annualized)
        uint256 termLength = 90 days;
        
        (uint256 loanId, uint256 loanOfferId) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward to due date
        vm.warp(block.timestamp + termLength);
        
        // Get detailed balance information before payment
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();
        uint256 totalAssetsBefore = bullaFactoring.totalAssets();

        // Pay loan
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalAmountDue = remainingPrincipal + interest;
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), totalAmountDue);
        bullaFrendLend.payLoan(loanId, totalAmountDue);
        vm.stopPrank();
        
        // Get detailed balance information after payment
        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalanceAfter = bullaFactoring.adminFeeBalance();
        uint256 totalAssetsAfter = bullaFactoring.totalAssets();
        
        // Verify fee balances increased appropriately
        uint256 protocolFeeIncrease = protocolFeeBalanceAfter - protocolFeeBalanceBefore;
        uint256 adminFeeIncrease = adminFeeBalanceAfter - adminFeeBalanceBefore;
        
        // Loan offers do not generate protocol fees
        assertEq(protocolFeeIncrease, 0, "Protocol fees do not apply to loan offers");
        assertGt(adminFeeIncrease, 0, "Admin fee should have increased");
        
        // Verify total assets increased due to interest earned
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should have increased from interest earned");
        
        // Verify fee calculations are proportional (annualized rates)
        uint256 loanDays = termLength / 1 days; // 90 days
        // Note: Protocol fees do not apply to loan offers, so expected is 0
        uint256 expectedProtocolFee = 0;
        // Note: Admin fee balance now includes both admin fee and spread
        uint256 expectedAdminFee = Math.mulDiv(
            Math.mulDiv(principalAmount, adminFeeBps, 10000),
            loanDays,
            365
        );
        uint256 expectedSpread = Math.mulDiv(
            Math.mulDiv(principalAmount, spreadBps, 10000),
            loanDays,
            365
        );
        uint256 expectedCombinedAdminFee = expectedAdminFee + expectedSpread;
        
        // Allow for some variance due to time-based calculations and rounding
        assertEq(protocolFeeIncrease, expectedProtocolFee, "Protocol fees do not apply to loan offers");
        assertApproxEqRel(adminFeeIncrease, expectedCombinedAdminFee, 0.1e18, "Admin fee should match expected annualized amount (includes spread)");
    }

    // ============= EDGE CASES =============
    
    function testLoanPayment_ZeroInterestLoan() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 0; // 0% APR target yield (annualized)
        uint16 spreadBps = 0; // 0% APR spread (annualized)
        uint256 termLength = 30 days;
        
        (uint256 loanId, uint256 loanOfferId) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Fast forward to due date
        vm.warp(block.timestamp + termLength);
        
        // Get amount due (should be just principal plus protocol/admin fees)
        (uint256 remainingPrincipal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalAmountDue = remainingPrincipal + interest;
        
        // Record balances
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 gainBefore = bullaFactoring.paidInvoicesGain(); // Record cumulative gain before payment
        
        // Pay loan
        vm.startPrank(bob);
        asset.approve(address(bullaFrendLend), totalAmountDue);
        bullaFrendLend.payLoan(loanId, totalAmountDue);
        vm.stopPrank();
        
        // Verify payment
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        assertEq(bobBalanceBefore - bobBalanceAfter, totalAmountDue, "Bob should have paid the amount due");
        
        // Verify minimal interest earned (only protocol/admin fees)
        uint256 gainAfter = bullaFactoring.paidInvoicesGain();
        uint256 totalInterest = gainAfter - gainBefore; // Calculate gain from this payment
        assertEq(totalInterest, 0, "Should have zero target yield and spread gains");
        
        // Only admin fees apply to loan offers - protocol fees do not
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fees do not apply to loan offers");
        assertGt(bullaFactoring.adminFeeBalance(), 0, "Admin fees should still apply");
    }
    
    function testLoanPayment_ReconcileWithoutNewPayments() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 1000;
        uint16 spreadBps = 500;
        uint256 termLength = 30 days;
        
        (uint256 loanId, uint256 loanOfferId) = createAndFundLoan(
            bob,
            principalAmount,
            targetYieldBps,
            spreadBps,
            termLength
        );
        
        // Record balances before reconciliation
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        
        // Record balances after reconciliation
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        
        // Verify no changes occurred
        assertEq(factoringBalanceAfter, factoringBalanceBefore, "Factoring balance should not change");
        
        // Loan should still be active
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertFalse(invoice.isPaid, "Loan should still be unpaid");
    }
} 
