// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import './CommonSetup.t.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBullaFrendLendV2, LoanRequestParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
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
        uint16 interestRateBps,
        uint16 numberOfPeriodsPerYear
    ) internal returns (uint256 loanId) {
        LoanRequestParams memory loanRequestParams = LoanRequestParams({
            termLength: termLength,
            interestConfig: InterestConfig({
                interestRateBps: interestRateBps,
                numberOfPeriodsPerYear: numberOfPeriodsPerYear
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
            interestRateBps,
            365
        );

        invoiceAdapterBulla.initializeInvoice(loanId);
        
        // Verify loan was created
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(invoice.creditor, bob, "Bob should be the creditor");
        assertEq(invoice.debtor, charlie, "Charlie should be the debtor");
        assertGe(invoice.invoiceAmount, principalAmount, "Invoice amount should be at least principal amount");
        assertEq(invoice.tokenAddress, address(asset), "Token should be asset");
        assertFalse(invoice.isPaid, "Loan should not be paid yet");
        
        // Underwriter approves the loan for factoring
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 200, 8000, 7, 0); // 7.3% yield, 2% spread, 80% upfront, 7 days min
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
            interestRateBps,
            365
        );

        invoiceAdapterBulla.initializeInvoice(loanId);
        
        // Verify initial state - starts at principal amount
        IInvoiceProviderAdapterV2.Invoice memory initialInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(initialInvoice.invoiceAmount, principalAmount, "Initial invoice amount should equal principal");
        
        // Fast forward 31 days - interest should have accrued
        vm.warp(block.timestamp + 31 days);
        
        IInvoiceProviderAdapterV2.Invoice memory midTermInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertGt(midTermInvoice.invoiceAmount, principalAmount, "Interest should have accrued over 31 days");
        
        // Fast forward to full term (31 days total)
        vm.warp(block.timestamp + 31 days);
        
        IInvoiceProviderAdapterV2.Invoice memory fullTermInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        
        // Verify that the loan has accrued interest
        assertGt(fullTermInvoice.invoiceAmount, principalAmount, "Loan should have interest component");
        
        // Verify interest accrues over time (even if it caps at some point)
        assertGe(fullTermInvoice.invoiceAmount, midTermInvoice.invoiceAmount, "Interest should not decrease over time");
        
                // The key validation: FrendLend loans accrue interest at the agreed rate
        // The exact amount depends on the BullaFrendLend implementation details
        uint256 interestAccrued = fullTermInvoice.invoiceAmount - principalAmount;
        assertGt(interestAccrued, 0, "Some interest should have accrued");
    }
    
    function testExternalFrendLoan_CompoundingFrequencyEffect() public {
        uint256 principalAmount = 100_000;
        uint256 termLength = 365 days; // 1 year term to maximize compounding effect
        uint16 interestRateBps = 1200; // 12% APR
        
        // Alice deposits funds to the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(400_000, alice);
        vm.stopPrank();
        
        // Create two identical loans with different compounding frequencies
        // Loan 1: Monthly compounding (12 periods per year)
        uint256 loanId1 = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps,
            12 // Monthly compounding
        );
        
        // Loan 2: Daily compounding (365 periods per year)
        uint256 loanId2 = createExternalFrendLoan(
            bob,
            charlie,
            principalAmount,
            termLength,
            interestRateBps,
            365 // Daily compounding
        );
        
        // Approve both loans for factoring with identical terms
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId1, 730, 300, 7500, 7, 0); // 7.3% target yield, 3% spread, 75% upfront
        bullaFactoring.approveInvoice(loanId2, 730, 300, 7500, 7, 0); // Identical factoring terms
        vm.stopPrank();
        
        // Factor both loans
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId1);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId2);
        uint256 fundedAmount1 = bullaFactoring.fundInvoice(loanId1, 7500, address(0));
        uint256 fundedAmount2 = bullaFactoring.fundInvoice(loanId2, 7500, address(0));
        vm.stopPrank();
        
        // Both loans should be funded with identical amounts (same factoring terms)
        assertEq(fundedAmount1, fundedAmount2, "Both loans should have identical funding amounts");
        
        // Fast forward to loan due date (1 year)
        vm.warp(block.timestamp + termLength);
        
        // Check accrued amounts before payment
        IInvoiceProviderAdapterV2.Invoice memory invoice1BeforePayment = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId1);
        IInvoiceProviderAdapterV2.Invoice memory invoice2BeforePayment = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId2);
        
        // Daily compounding should result in higher invoice amount than monthly compounding
        assertGt(invoice2BeforePayment.invoiceAmount, invoice1BeforePayment.invoiceAmount, 
            "Daily compounding should result in higher invoice amount");
        
        // Record initial fee balances before any payments
        uint256 initialAdminFeeBalance = bullaFactoring.adminFeeBalance();
        uint256 initialProtocolFeeBalance = bullaFactoring.protocolFeeBalance();
        uint256 gainBeforeLoans = bullaFactoring.paidInvoicesGain(); // Record initial cumulative gain
        
        // Pay and reconcile loan 1 (monthly compounding) first
        vm.startPrank(charlie);
        (uint256 principal1, uint256 interest1) = bullaFrendLend.getTotalAmountDue(loanId1);
        uint256 totalDue1 = principal1 + interest1;
        asset.approve(address(bullaFrendLend), totalDue1);
        bullaFrendLend.payLoan(loanId1, totalDue1);
        vm.stopPrank();
        
        
        
        // Capture fee balances after loan 1 payment
        uint256 adminFeeAfterLoan1 = bullaFactoring.adminFeeBalance();
        uint256 protocolFeeAfterLoan1 = bullaFactoring.protocolFeeBalance();
        uint256 gainAfterLoan1 = bullaFactoring.paidInvoicesGain();
        
        // Pay and reconcile loan 2 (daily compounding)
        vm.startPrank(charlie);
        (uint256 principal2, uint256 interest2) = bullaFrendLend.getTotalAmountDue(loanId2);
        uint256 totalDue2 = principal2 + interest2;
        asset.approve(address(bullaFrendLend), totalDue2);
        bullaFrendLend.payLoan(loanId2, totalDue2);
        vm.stopPrank();
        
        
        
        // Capture final fee balances after loan 2 payment
        uint256 finalAdminFeeBalance = bullaFactoring.adminFeeBalance();
        uint256 finalProtocolFeeBalance = bullaFactoring.protocolFeeBalance();
        uint256 gainAfterLoan2 = bullaFactoring.paidInvoicesGain();
        
        // Calculate individual loan contributions to fees and gains
        uint256 adminFeeFromLoan1 = adminFeeAfterLoan1 - initialAdminFeeBalance;
        uint256 adminFeeFromLoan2 = finalAdminFeeBalance - adminFeeAfterLoan1;
        uint256 protocolFeeFromLoan1 = protocolFeeAfterLoan1 - initialProtocolFeeBalance;
        uint256 protocolFeeFromLoan2 = finalProtocolFeeBalance - protocolFeeAfterLoan1;
        uint256 gainFromLoan1 = gainAfterLoan1 - gainBeforeLoans;
        uint256 gainFromLoan2 = gainAfterLoan2 - gainAfterLoan1;
        
        // Critical validation: daily compounding loan should generate higher gains and fees than monthly compounding
        assertGt(gainFromLoan2, gainFromLoan1, "Daily compounding loan should generate higher pool gains");
        assertGt(adminFeeFromLoan2, adminFeeFromLoan1, "Daily compounding loan should generate higher admin fees");
        // Note: Loan offers do not generate protocol fees - only admin fees apply
        assertEq(protocolFeeFromLoan1, 0, "Loan offers do not generate protocol fees");
        assertEq(protocolFeeFromLoan2, 0, "Loan offers do not generate protocol fees");
        
        // Get final invoice details to check total amounts
        IInvoiceProviderAdapterV2.Invoice memory finalInvoice1 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId1);
        IInvoiceProviderAdapterV2.Invoice memory finalInvoice2 = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId2);
        
        // Verify that daily compounding resulted in higher total payment
        assertGt(finalInvoice2.invoiceAmount, finalInvoice1.invoiceAmount, 
            "Daily compounding should result in higher total invoice amount");
        
        // Calculate the extra interest generated by daily vs monthly compounding
        uint256 extraInterest = finalInvoice2.invoiceAmount - finalInvoice1.invoiceAmount;
        assertGt(extraInterest, 0, "Daily compounding should generate additional interest over monthly");
        
        // Verify individual loan contributions are positive
        assertGt(gainFromLoan1, 0, "Monthly compounding loan should generate positive pool gains");
        assertGt(gainFromLoan2, 0, "Daily compounding loan should generate positive pool gains");
        assertGt(adminFeeFromLoan1, 0, "Monthly compounding loan should generate positive admin fees");
        assertGt(adminFeeFromLoan2, 0, "Daily compounding loan should generate positive admin fees");
        // Note: Loan offers do not generate protocol fees
        assertEq(protocolFeeFromLoan1, 0, "Loan offers do not generate protocol fees");
        assertEq(protocolFeeFromLoan2, 0, "Loan offers do not generate protocol fees");
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
            interestRateBps,
            365
        );
        
        // Approve and factor the loan
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 300, 7500, 10, 0); // 10 days minimum
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
        
        // Verify loan is paid
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(invoice.isPaid, "Loan should be paid");
        
        // Verify pool gained from the loan
        uint256 gain = bullaFactoring.paidInvoicesGain();
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
            interestRateBps,
            365
        );
        
        // Approve and factor the loan
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 365, 150, 6000, 5, 0); // 3.65% yield, 1.5% spread, 60% upfront, 5 days min
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
        
        // Verify final payment
        IInvoiceProviderAdapterV2.Invoice memory finalInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(finalInvoice.isPaid, "Loan should be fully paid");
        
        uint256 gain = bullaFactoring.paidInvoicesGain();
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
            interestRateBps,
            365
        );
        
        // Approve and factor the loan
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 400, 7000, 14, 0); // 14 days minimum
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
        uint256 gain = bullaFactoring.paidInvoicesGain();
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
        uint256 loanId1 = createExternalFrendLoan(bob, charlie, principalAmount, termLength, interestRateBps, 365);
        uint256 loanId2 = createExternalFrendLoan(bob, charlie, principalAmount, termLength, interestRateBps, 365);
        uint256 loanId3 = createExternalFrendLoan(bob, charlie, principalAmount, termLength, interestRateBps, 365);
        
        // Approve all loans for factoring
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId1, 730, 200, 8000, 7, 0);
        bullaFactoring.approveInvoice(loanId2, 730, 200, 8000, 7, 0);
        bullaFactoring.approveInvoice(loanId3, 730, 200, 8000, 7, 0);
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
        uint256 gainBefore = bullaFactoring.paidInvoicesGain();

        (uint256 principal1, uint256 interest1) = bullaFrendLend.getTotalAmountDue(loanId1);
        asset.approve(address(bullaFrendLend), principal1 + interest1);
        bullaFrendLend.payLoan(loanId1, principal1 + interest1);
        
        uint256 gainAfterLoan1 = bullaFactoring.paidInvoicesGain();
        uint256 gain1 = gainAfterLoan1 - gainBefore;
        
        (uint256 principal2, uint256 interest2) = bullaFrendLend.getTotalAmountDue(loanId2);
        asset.approve(address(bullaFrendLend), principal2 + interest2);
        bullaFrendLend.payLoan(loanId2, principal2 + interest2);
        
        
        uint256 gainAfterLoan2 = bullaFactoring.paidInvoicesGain();
        uint256 gain2 = gainAfterLoan2 - gainAfterLoan1;

        (uint256 principal3, uint256 interest3) = bullaFrendLend.getTotalAmountDue(loanId3);
        asset.approve(address(bullaFrendLend), principal3 + interest3);
        bullaFrendLend.payLoan(loanId3, principal3 + interest3);

        
        uint256 gainAfterLoan3 = bullaFactoring.paidInvoicesGain();
        uint256 gain3 = gainAfterLoan3 - gainAfterLoan2;
        
        vm.stopPrank();
        
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
            interestRateBps,
            365
        );
        
        // Try to factor without approval - should fail
        vm.startPrank(bob);
        IERC721(address(bullaFrendLend)).approve(address(bullaFactoring), loanId);
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotApproved()"));
        bullaFactoring.fundInvoice(loanId, 8000, address(0));
        vm.stopPrank();
        
        // Approve with invalid upfront percentage
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(loanId, 730, 200, 8000, 7, 0);
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
    
    // Helper function to bound fuzz parameters
    function _boundFuzzParameters(
        uint256 principalAmount,
        uint16 targetYieldBps,
        uint16 spreadBps,
        uint16 numberOfPeriodsPerYear,
        uint256 termLength
    ) internal pure returns (uint256, uint16, uint16, uint16, uint256) {
        principalAmount = bound(principalAmount, 10_000, 1_000_000); // $10K to $1M
        targetYieldBps = uint16(bound(uint256(targetYieldBps), 500, 5000)); // 5% to 50% APR
        spreadBps = uint16(bound(uint256(spreadBps), 1000, 2000)); // 10% to 20% spread
        numberOfPeriodsPerYear = uint16(bound(uint256(numberOfPeriodsPerYear), 4, 365)); // 4 to 365 periods per year (quarterly to daily)
        termLength = bound(termLength, 365 days, 3 * 365 days); // 1 year to 3 years
        
        return (principalAmount, targetYieldBps, spreadBps, numberOfPeriodsPerYear, termLength);
    }
    
    // Helper function to create and accept loan offer
    function _createAndAcceptLoan(
        uint256 principalAmount,
        uint16 targetYieldBps,
        uint16 spreadBps,
        uint16 numberOfPeriodsPerYear,
        uint256 termLength
    ) internal returns (uint256 loanId) {
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(
            charlie, // debtor
            targetYieldBps,
            spreadBps,
            principalAmount,
            termLength,
            numberOfPeriodsPerYear,
            "Fuzz test loan"
        );
        vm.stopPrank();
        
        vm.startPrank(charlie);
        loanId = bullaFrendLend.acceptLoan(loanOfferId);
        vm.stopPrank();
        
        return loanId;
    }
    
    // Helper function to pay loan and reconcile
    function _payLoanAndReconcile(uint256 loanId, uint256 termLength) internal {
        vm.warp(block.timestamp + termLength / 2); // Pay at halfway point
        
        vm.startPrank(charlie);
        (uint256 principal, uint256 interest) = bullaFrendLend.getTotalAmountDue(loanId);
        uint256 totalDue = principal + interest;
        
        if (asset.balanceOf(charlie) < totalDue) {
            deal(address(asset), charlie, totalDue);
        }
        
        asset.approve(address(bullaFrendLend), totalDue);
        bullaFrendLend.payLoan(loanId, totalDue);
        vm.stopPrank();
        
        
    }
    
    function testFuzz_OfferLoanNeverFailsNorGeneratesKickback(
        uint256 principalAmount,
        uint16 targetYieldBps,
        uint16 spreadBps,
        uint16 numberOfPeriodsPerYear,
        uint256 termLength
    ) public {
        // Bound parameters using helper function
        (principalAmount, targetYieldBps, spreadBps, numberOfPeriodsPerYear, termLength) = 
            _boundFuzzParameters(principalAmount, targetYieldBps, spreadBps, numberOfPeriodsPerYear, termLength);
        
        // Alice deposits sufficient funds
        vm.startPrank(alice);
        bullaFactoring.deposit(2_000_000, alice);
        vm.stopPrank();

        uint256 initialPoolBalance = bullaFactoring.totalAssets();
        
        // Create and accept loan
        uint256 loanId = _createAndAcceptLoan(principalAmount, targetYieldBps, spreadBps, numberOfPeriodsPerYear, termLength);
        
        IInvoiceProviderAdapterV2.Invoice memory invoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertEq(invoice.creditor, address(bullaFactoring), "Factoring contract should be the creditor");
        assertFalse(invoice.isPaid, "Loan should not be paid initially");
        
        // Pay loan and reconcile
        _payLoanAndReconcile(loanId, termLength);
        
        // Verify loan is paid
        IInvoiceProviderAdapterV2.Invoice memory paidInvoice = bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(loanId);
        assertTrue(paidInvoice.isPaid, "Loan should be marked as paid");
        
        // Critical validation: No kickback for pool-offered loans
        (uint256 kickbackAmount, uint256 trueInterest, , ) = bullaFactoring.calculateKickbackAmount(loanId);
        assertEq(kickbackAmount, 0, "offerLoan should never generate kickbacks when paid");
        
        // Verify pool balance increase
        uint256 finalPoolBalance = bullaFactoring.totalAssets();
        uint256 poolBalanceIncrease = finalPoolBalance - initialPoolBalance;
        assertEq(poolBalanceIncrease, trueInterest, "Pool balance should increase by exactly the target yield interest");
        
        // Verify pool gains
        uint256 poolGain = bullaFactoring.paidInvoicesGain();
        assertGt(poolGain, 0, "Pool should have recorded gains from the loan");
    }
} 
