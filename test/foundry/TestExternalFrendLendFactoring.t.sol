// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import './CommonSetup.t.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBullaFrendLend, LoanRequestParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaFrendLend.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/BullaClaim.sol";
import {EIP712Helper} from "./utils/EIP712Helper.sol";

contract TestExternalFrendLendFactoring is CommonSetup {
    EIP712Helper public sigHelper;
    
    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));
        
        // Add Bob and Charlie to feeExemption whitelist so they can create/accept loans
        feeExemptionWhitelist.allow(bob);
        feeExemptionWhitelist.allow(charlie);
        
        // Set up permitCreateClaim for Bob to create loans via BullaFrendLend
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: bob,
            controller: address(bullaFrendLend),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
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
        
        // Set up permitCreateClaim for Charlie to accept loans via BullaFrendLend
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
    
    // Helper function to create external FrendLend loan
    function createExternalFrendLoan(
        address creditor,
        address debtor,
        uint256 principalAmount,
        uint256 termLength,
        uint16 interestRateBps
    ) internal returns (uint256 loanId) {
        LoanRequestParams memory loanRequestParams = LoanRequestParams({
            termLength: termLength,
            interestConfig: InterestConfig({
                interestRateBps: interestRateBps,
                numberOfPeriodsPerYear: 365
            }),
            loanAmount: principalAmount,
            creditor: creditor,
            debtor: debtor,
            description: "External FrendLend loan",
            token: address(asset),
            impairmentGracePeriod: 60 days,
            expiresAt: block.timestamp + 1 hours,
            callbackContract: address(0),
            callbackSelector: bytes4(0)
        });
        
        vm.startPrank(creditor);
        asset.approve(address(bullaFrendLend), principalAmount);
        loanId = bullaFrendLend.offerLoan(loanRequestParams);
        vm.stopPrank();
        
        // Debtor accepts the loan - interest starts accruing from this point
        vm.prank(debtor);
        bullaFrendLend.acceptLoan(loanId);
        
        return loanId;
    }
    
    function testCreateExternalFrendLoan_BasicFlow() public {
        uint256 principalAmount = 100_000;
        uint256 termLength = 30 days;
        uint16 interestRateBps = 1825; // 18.25% APR - agreed interest rate
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(200_000, alice);
        vm.stopPrank();
        
        // Bob creates an external loan to Charlie with agreed interest rate
        uint256 loanId = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps
        );
        
        // Verify loan was created
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(invoice.creditor, bob, "Bob should be the creditor");
        assertEq(invoice.debtor, charlie, "Charlie should be the debtor");
        assertGe(invoice.invoiceAmount, principalAmount, "Invoice amount should be at least principal amount");
        assertEq(invoice.tokenAddress, address(asset), "Token should be asset");
        assertFalse(invoice.isPaid, "Loan should not be paid yet");
        
        // Underwriter approves the loan for factoring
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 200, 8000, 7); // 7.3% yield, 2% spread, 80% upfront, 7 days min
        vm.stopPrank();
        
        // Bob factors the loan
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(loanId, 8000, address(0));
        vm.stopPrank();
        
        assertGt(fundedAmount, 0, "Should have funded the loan");
        
        // Verify loan is now owned by the factoring contract
        IInvoiceProviderAdapterV2.Invoice memory factoredInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(factoredInvoice.creditor, address(bullaFactoring), "Factoring contract should now own the loan");
    }
    
    function testExternalFrendLoan_InterestAccrualValidation() public {
        uint256 principalAmount = 100_000;
        uint256 termLength = 30 days;
        uint16 interestRateBps = 1200; // 12% APR
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(200_000, alice);
        vm.stopPrank();
        
        // Bob creates an external loan to Charlie
        uint256 loanId = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps
        );
        
        // Verify initial state - starts at principal amount
        IInvoiceProviderAdapterV2.Invoice memory initialInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(initialInvoice.invoiceAmount, principalAmount, "Initial invoice amount should equal principal");
        
        // Fast forward 15 days - interest should have accrued
        vm.warp(block.timestamp + 15 days);
        
        IInvoiceProviderAdapterV2.Invoice memory midTermInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertGt(midTermInvoice.invoiceAmount, principalAmount, "Interest should have accrued over 15 days");
        
        // Fast forward to full term (30 days total)
        vm.warp(block.timestamp + 15 days);
        
        IInvoiceProviderAdapterV2.Invoice memory fullTermInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        
        // Verify that the loan has accrued interest
        assertGt(fullTermInvoice.invoiceAmount, principalAmount, "Loan should have interest component");
        
        // Verify interest accrues over time (even if it caps at some point)
        assertGe(fullTermInvoice.invoiceAmount, midTermInvoice.invoiceAmount, "Interest should not decrease over time");
        
        // The key validation: FrendLend loans accrue interest at the agreed rate
        // The exact amount depends on the BullaFrendLend implementation details
        uint256 interestAccrued = fullTermInvoice.invoiceAmount - principalAmount;
        assertGt(interestAccrued, 0, "Some interest should have accrued");
        
        // Verify reasonable bounds (should be less than full term at the agreed rate)
        uint256 maxExpectedInterest = Math.mulDiv(principalAmount, interestRateBps, 10000) * 30 / 365;
        assertLe(interestAccrued, maxExpectedInterest, "Interest should not exceed theoretical maximum");
    }
    
    function testExternalFrendLoan_PoolGainIndependentOfLoanInterestRate() public {
        uint256 principalAmount = 100_000;
        uint256 termLength = 30 days;
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(400_000, alice);
        vm.stopPrank();
        
        // Create two identical external loans with different interest rates
        uint256 loanId1 = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            1825 // 18.25% APR (higher interest rate)
        );
        
        uint256 loanId2 = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            0 // 0% APR (no interest)
        );
        
        // Approve both loans for factoring with identical terms
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId1, 730, 200, 8000, 7); // 7.3% target yield, 2% spread
        bullaFactoring.approveInvoice(loanId2, 730, 200, 8000, 7); // Identical factoring terms
        vm.stopPrank();
        
        // Factor both loans
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId1);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId2);
        uint256 fundedAmount1 = bullaFactoring.fundInvoice(loanId1, 8000, address(0));
        uint256 fundedAmount2 = bullaFactoring.fundInvoice(loanId2, 8000, address(0));
        vm.stopPrank();
        
        // Both loans should be funded with identical amounts (same factoring terms)
        assertEq(fundedAmount1, fundedAmount2, "Both loans should have identical funding amounts");
        
        // Fast forward to loan due date
        vm.warp(block.timestamp + termLength);
        
        // Charlie pays both loans in full
        vm.startPrank(charlie);
        
        // Pay loan 1 (with accrued interest at 18.25% APR)
        (uint256 principal1, uint256 interest1) = bullaFrendLend.getTotalAmountDue(loanId1);
        uint256 totalDue1 = principal1 + interest1;
        asset.approve(address(bullaFrendLend), totalDue1);
        bullaFrendLend.payLoan(loanId1, totalDue1);
        
        // Pay loan 2 (no interest accrued)
        (uint256 principal2, uint256 interest2) = bullaFrendLend.getTotalAmountDue(loanId2);
        uint256 totalDue2 = principal2 + interest2;
        asset.approve(address(bullaFrendLend), totalDue2);
        bullaFrendLend.payLoan(loanId2, totalDue2);
        
        vm.stopPrank();
        
        // Reconcile both loans
        bullaFactoring.reconcileActivePaidInvoices();
        
        // Get pool gains for both loans
        uint256 gain1 = bullaFactoring.paidInvoicesGain(loanId1);
        uint256 gain2 = bullaFactoring.paidInvoicesGain(loanId2);
        
        // Verify loan 1 had higher total payment due to agreed interest rate
        assertGt(totalDue1, totalDue2, "Loan 1 should have paid more due to higher interest rate");
        
        // Critical validation: pool gains should be identical
        // The underlying loan's interest rate should not affect the factoring pool's gain
        assertEq(gain1, gain2, "Pool gains must be equal - underlying loan interest rates don't affect pool gains");
        
        // The difference in payment amounts goes to the original lender (Bob)
        IInvoiceProviderAdapterV2.Invoice memory invoice1 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId1);
        IInvoiceProviderAdapterV2.Invoice memory invoice2 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId2);
        
        uint256 totalPaymentDifference = invoice1.invoiceAmount - invoice2.invoiceAmount;
        assertGt(totalPaymentDifference, 0, "Loan 1 should have higher total amount due to agreed interest rate");
    }
    
    function testExternalFrendLoan_EarlyPayment() public {
        uint256 principalAmount = 150_000;
        uint256 termLength = 60 days;
        uint16 interestRateBps = 1460; // 14.6% APR - agreed interest rate
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(300_000, alice);
        vm.stopPrank();
        
        // Bob creates external loan to Charlie with agreed interest terms
        uint256 loanId = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps
        );
        
        // Approve and factor the loan
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 300, 7500, 10); // 10 days minimum
        vm.stopPrank();
        
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId);
        bullaFactoring.fundInvoice(loanId, 7500, address(0));
        vm.stopPrank();
        
        // Fast forward 20 days (early payment - less interest accrued)
        vm.warp(block.timestamp + 20 days);
        
        // Charlie pays early (less interest accrued than full term)
        vm.startPrank(charlie);
        (uint256 principal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalDue = principal + interest;
        asset.approve(address(bullaFrendLend), totalDue);
        bullaFrendLend.payLoan(loanId, totalDue);
        vm.stopPrank();
        
        // Reconcile
        bullaFactoring.reconcileActivePaidInvoices();
        
        // Verify loan is paid
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(invoice.isPaid, "Loan should be paid");
        
        // Verify pool gained from the loan
        uint256 gain = bullaFactoring.paidInvoicesGain(loanId);
        assertGt(gain, 0, "Pool should have gained from the loan");
        
        // Early payment should result in lower factoring gain than full term
        uint256 expectedFullTermGain = Math.mulDiv(
            Math.mulDiv(principalAmount, 730, 10000), // 7.3% target yield
            60, // full term days
            365
        );
        
        assertLt(gain, expectedFullTermGain, "Early payment should result in lower factoring gain than full term");
    }
    
    function testExternalFrendLoan_PartialPayment() public {
        uint256 principalAmount = 80_000;
        uint256 termLength = 45 days;
        uint16 interestRateBps = 1095; // 10.95% APR
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(160_000, alice);
        vm.stopPrank();
        
        // Bob creates external loan to Charlie
        uint256 loanId = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps
        );
        
        // Approve and factor the loan
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 365, 150, 6000, 5); // 3.65% yield, 1.5% spread, 60% upfront, 5 days min
        vm.stopPrank();
        
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId);
        bullaFactoring.fundInvoice(loanId, 6000, address(0));
        vm.stopPrank();
        
        // Fast forward 15 days
        vm.warp(block.timestamp + 15 days);
        
        // Charlie makes partial payment
        uint256 partialPayment = 30_000;
        vm.startPrank(charlie);
        asset.approve(address(bullaFrendLend), partialPayment);
        bullaFrendLend.payLoan(loanId, partialPayment);
        vm.stopPrank();
        
        // Verify loan is not fully paid yet
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterPartial = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertFalse(invoiceAfterPartial.isPaid, "Loan should not be fully paid after partial payment");
        assertGt(invoiceAfterPartial.paidAmount, 0, "Should have recorded partial payment");
        
        // Fast forward to due date
        vm.warp(block.timestamp + 30 days);
        
        // Charlie pays remaining balance
        vm.startPrank(charlie);
        (uint256 principal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 remainingDue = principal + interest;
        asset.approve(address(bullaFrendLend), remainingDue);
        bullaFrendLend.payLoan(loanId, remainingDue);
        vm.stopPrank();
        
        // Reconcile
        bullaFactoring.reconcileActivePaidInvoices();
        
        // Verify final payment
        IInvoiceProviderAdapterV2.Invoice memory finalInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(finalInvoice.isPaid, "Loan should be fully paid");
        
        uint256 gain = bullaFactoring.paidInvoicesGain(loanId);
        assertGt(gain, 0, "Pool should have gained from the loan");
    }
    
    function testExternalFrendLoan_Unfactoring() public {
        uint256 principalAmount = 120_000;
        uint256 termLength = 30 days;
        uint16 interestRateBps = 1825; // 18.25% APR
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(240_000, alice);
        vm.stopPrank();
        
        // Bob creates external loan to Charlie
        uint256 loanId = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps
        );
        
        // Approve and factor the loan
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 400, 7000, 14); // 14 days minimum
        vm.stopPrank();
        
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId);
        bullaFactoring.fundInvoice(loanId, 7000, address(0));
        vm.stopPrank();
        
        // Fast forward 10 days
        vm.warp(block.timestamp + 10 days);
        
        // Bob decides to unfactor the loan
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(loanId);
        vm.stopPrank();
        
        // Verify loan is back to Bob
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(invoice.creditor, bob, "Bob should be the creditor again");
        
        // Verify Bob paid back the loan plus interest
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        assertLt(bobBalanceAfter, bobBalanceBefore, "Bob should have paid to unfactor the loan");
        
        // Verify pool gained from the unfactoring
        uint256 gain = bullaFactoring.paidInvoicesGain(loanId);
        assertGt(gain, 0, "Pool should have gained from unfactoring");
    }
    
    function testExternalFrendLoan_MultipleLoansFromSameCreditor() public {
        uint256 principalAmount = 50_000;
        uint256 termLength = 30 days;
        uint16 interestRateBps = 1460; // 14.6% APR
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(300_000, alice);
        vm.stopPrank();
        
        // Bob creates multiple external loans to Charlie
        uint256 loanId1 = createExternalFrendLoan(bob, charlie, principalAmount, termLength, interestRateBps);
        uint256 loanId2 = createExternalFrendLoan(bob, charlie, principalAmount, termLength, interestRateBps);
        uint256 loanId3 = createExternalFrendLoan(bob, charlie, principalAmount, termLength, interestRateBps);
        
        // Approve all loans for factoring
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId1, 730, 200, 8000, 7);
        bullaFactoring.approveInvoice(loanId2, 730, 200, 8000, 7);
        bullaFactoring.approveInvoice(loanId3, 730, 200, 8000, 7);
        vm.stopPrank();
        
        // Factor all loans
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId1);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId2);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId3);
        
        uint256 fundedAmount1 = bullaFactoring.fundInvoice(loanId1, 8000, address(0));
        uint256 fundedAmount2 = bullaFactoring.fundInvoice(loanId2, 8000, address(0));
        uint256 fundedAmount3 = bullaFactoring.fundInvoice(loanId3, 8000, address(0));
        vm.stopPrank();
        
        // All loans should be funded with identical amounts
        assertEq(fundedAmount1, fundedAmount2, "Loans 1 and 2 should have identical funding");
        assertEq(fundedAmount2, fundedAmount3, "Loans 2 and 3 should have identical funding");
        
        // Fast forward to due date
        vm.warp(block.timestamp + termLength);
        
        // Charlie pays all loans
        vm.startPrank(charlie);
        
        (uint256 principal1, uint256 interest1) = bullaFrendLend.getTotalAmountDue(loanId1);
        asset.approve(address(bullaFrendLend), principal1 + interest1);
        bullaFrendLend.payLoan(loanId1, principal1 + interest1);
        
        (uint256 principal2, uint256 interest2) = bullaFrendLend.getTotalAmountDue(loanId2);
        asset.approve(address(bullaFrendLend), principal2 + interest2);
        bullaFrendLend.payLoan(loanId2, principal2 + interest2);
        
        (uint256 principal3, uint256 interest3) = bullaFrendLend.getTotalAmountDue(loanId3);
        asset.approve(address(bullaFrendLend), principal3 + interest3);
        bullaFrendLend.payLoan(loanId3, principal3 + interest3);
        
        vm.stopPrank();
        
        // Reconcile
        bullaFactoring.reconcileActivePaidInvoices();
        
        // Verify all loans are paid and pool gained from each
        uint256 gain1 = bullaFactoring.paidInvoicesGain(loanId1);
        uint256 gain2 = bullaFactoring.paidInvoicesGain(loanId2);
        uint256 gain3 = bullaFactoring.paidInvoicesGain(loanId3);
        
        assertGt(gain1, 0, "Pool should have gained from loan 1");
        assertGt(gain2, 0, "Pool should have gained from loan 2");
        assertGt(gain3, 0, "Pool should have gained from loan 3");
        
        // Gains should be identical since loans were identical
        assertEq(gain1, gain2, "Gains from loans 1 and 2 should be identical");
        assertEq(gain2, gain3, "Gains from loans 2 and 3 should be identical");
    }
    
    function testExternalFrendLoan_ErrorHandling() public {
        uint256 principalAmount = 75_000;
        uint256 termLength = 30 days;
        uint16 interestRateBps = 1095; // 10.95% APR
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(150_000, alice);
        vm.stopPrank();
        
        // Bob creates external loan to Charlie
        uint256 loanId = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps
        );
        
        // Try to factor without approval - should fail
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId);
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotApproved()"));
        bullaFactoring.fundInvoice(loanId, 8000, address(0));
        vm.stopPrank();
        
        // Approve with invalid upfront percentage
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 200, 8000, 7);
        vm.stopPrank();
        
        // Try to factor with too high upfront percentage - should fail
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.fundInvoice(loanId, 9000, address(0)); // 90% > 80% approved
        vm.stopPrank();
        
        // Try to factor with zero upfront percentage - should fail
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.fundInvoice(loanId, 0, address(0));
        vm.stopPrank();
        
        // Factor successfully
        vm.startPrank(bob);
        uint256 fundedAmount = bullaFactoring.fundInvoice(loanId, 8000, address(0));
        vm.stopPrank();
        
        assertGt(fundedAmount, 0, "Should have funded the loan");
        
        // Try to factor again - should fail since creditor changed
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("InvoiceCreditorChanged()"));
        bullaFactoring.fundInvoice(loanId, 8000, address(0));
        vm.stopPrank();
    }
} 