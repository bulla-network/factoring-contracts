// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import {CreateInvoiceParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {InterestComputationState} from "bulla-contracts-v2/src/libraries/CompoundInterestLib.sol";
import {ClaimBinding, CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
import {EIP712Helper} from './utils/EIP712Helper.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "contracts/interfaces/IBullaFactoring.sol";

contract TestBullaInvoiceFactoring is CommonSetup {
    
    EIP712Helper public sigHelper;
    
    // Events to test
    event InvoiceApproved(uint256 indexed invoiceId, uint256 validUntil, IBullaFactoringV2.FeeParams feeParams);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed factorer, uint256 invoiceDueDate, uint16 upfrontBps);
    event InvoicePaid(uint256 indexed invoiceId, uint256 targetInterest, uint256 spreadAmount, uint256 protocolFee, uint256 adminFee, uint256 fundedAmount, uint256 kickbackAmount, address indexed originalCreditor);
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);

    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Set up approval for bob to create invoices through BullaInvoice
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: bob,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max, // Max approvals
            isBindingAllowed: true,
            signature: sigHelper.signCreateClaimPermit({
                pk: bobPK,
                user: bob,
                controller: address(bullaInvoice),
                approvalType: CreateClaimApprovalType.Approved,
                approvalCount: type(uint64).max,
                isBindingAllowed: true
            })
        });
    }

    function testCreateAndApproveBasicBullaInvoice() public {
        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365; // Daily compounding
        uint256 _dueBy = block.timestamp + 60 days;

        // Create BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        // Verify invoice was created properly
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoice.creditor, bob);
        assertEq(invoice.debtor, alice);
        assertEq(invoice.tokenAddress, address(asset));
        assertEq(invoice.dueDate, _dueBy);
        assertFalse(invoice.isPaid);
        assertFalse(invoice.isCanceled);

        // Approve invoice for factoring
        vm.startPrank(underwriter);
        vm.expectEmit(true, false, false, true);
        emit InvoiceApproved(invoiceId, block.timestamp + bullaFactoring.approvalDuration(), IBullaFactoringV2.FeeParams({
            targetYieldBps: interestApr,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            protocolFeeBps: protocolFeeBps,
            adminFeeBps: adminFeeBps,
            minDaysInterestApplied: minDays
        }));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Verify approval
        (bool approved, , , , , , , , , , ) = bullaFactoring.approvedInvoices(invoiceId);
        assertTrue(approved);
    }

    function testFundBullaInvoiceWithInterestCalculation() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1200; // 12% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create and approve BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Calculate expected fees
        (, , uint256 targetInterest, uint256 targetSpreadAmount, , uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);

        // Fund the invoice
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        
        vm.expectEmit(true, false, false, true);
        emit InvoiceFunded(invoiceId, netFundedAmount, bob, _dueBy, upfrontBps);
        
        uint256 actualFundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        assertEq(actualFundedAmount, netFundedAmount);
        assertGt(netFundedAmount, 0);
        assertGt(targetInterest, 0);
        assertGt(targetSpreadAmount, 0);

        // Verify invoice ownership transferred
        assertEq(IERC721(address(bullaInvoice)).ownerOf(invoiceId), address(bullaFactoring));
    }

    function testBullaInvoicePaymentWithInterestAccrual() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1500; // 15% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward 45 days (before due date)
        vm.warp(block.timestamp + 45 days);

        // Get total amount due (principal + accrued interest)
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        uint256 totalAmountDue = invoice.invoiceAmount;

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();

        // Debtor pays the full amount including accrued interest
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), totalAmountDue);
        bullaInvoice.payInvoice(invoiceId, totalAmountDue);
        vm.stopPrank();

        // Reconcile and verify payment processing
        bullaFactoring.reconcileActivePaidInvoices();

        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase after profitable invoice payment");

        // Verify invoice is marked as paid
        IInvoiceProviderAdapterV2.Invoice memory paidInvoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertTrue(paidInvoice.isPaid);
    }

    function testBullaInvoiceEarlyPaymentKickback() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1800; // 18% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 90 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        // Pay early (30 days instead of 90)
        vm.warp(block.timestamp + 30 days);

        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        uint256 totalAmountDue = invoice.invoiceAmount;

        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), totalAmountDue);
        bullaInvoice.payInvoice(invoiceId, totalAmountDue);
        vm.stopPrank();

        // Calculate expected kickback
        (uint256 kickbackAmount, , , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);

        // Reconcile and check for kickback payment
        if (kickbackAmount > 0) {
            vm.expectEmit(true, false, false, true);
            emit InvoiceKickbackAmountSent(invoiceId, kickbackAmount, bob);
        }

        bullaFactoring.reconcileActivePaidInvoices();

        uint256 bobBalanceAfter = asset.balanceOf(bob);
        if (kickbackAmount > 0) {
            assertEq(bobBalanceAfter - bobBalanceBefore, kickbackAmount, "Bob should receive kickback for early payment");
        }
    }

    function testBullaInvoicePartialPayment() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Make partial payment
        uint256 partialPayment = 30000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPayment);
        bullaInvoice.payInvoice(invoiceId, partialPayment);
        vm.stopPrank();

        // Verify partial payment recorded
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertGt(invoice.paidAmount, 0);
        assertFalse(invoice.isPaid); // Should not be fully paid yet

        // Complete payment later
        vm.warp(block.timestamp + 30 days);
        
        invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        uint256 remainingAmount = invoice.invoiceAmount - invoice.paidAmount;

        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), remainingAmount);
        bullaInvoice.payInvoice(invoiceId, remainingAmount);
        vm.stopPrank();

        // Verify full payment
        invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertTrue(invoice.isPaid);

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        // Reconcile and verify proper accounting
        bullaFactoring.reconcileActivePaidInvoices();

        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase after full payment");
    }

    function testBullaInvoiceImpairmentScenario() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 50000;
        vm.startPrank(address(this)); // Owner
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Let invoice become overdue (beyond grace period)
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        // Owner impairs the invoice
        vm.startPrank(address(this)); // Owner
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // Verify impairment
        (uint256 gainAmount, uint256 lossAmount, bool isImpaired) = bullaFactoring.impairments(invoiceId);
        assertTrue(isImpaired);
        assertGt(lossAmount, 0);
        assertGt(gainAmount, 0);
    }

    function testBullaInvoiceUnfactoring() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        // Wait some time for interest to accrue
        vm.warp(block.timestamp + 15 days);

        // Bob decides to unfactor the invoice
        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), type(uint256).max); // Approve max for unfactoring cost
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();

        // Verify invoice ownership returned to Bob
        assertEq(IERC721(address(bullaInvoice)).ownerOf(invoiceId), bob);

        // Verify Bob paid back the appropriate amount (funded amount + accrued fees)
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        assertLt(bobBalanceAfter, bobBalanceBefore); // Bob should have paid something to unfactor
    }

    function testBullaInvoiceFactoringWithDifferentUpfrontBps() public {
        uint256 initialDeposit = 300000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;
        uint16 approvedUpfrontBps = 9000; // 90%
        uint16 factorerChosenUpfrontBps = 7500; // 75%

        // Create and approve BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId1 = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        uint256 invoiceId2 = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, approvedUpfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, approvedUpfrontBps, minDays, 0);
        vm.stopPrank();

        // Fund first invoice with approved upfront bps
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId1);
        uint256 fundedAmount1 = bullaFactoring.fundInvoice(invoiceId1, approvedUpfrontBps, address(0));
        
        // Fund second invoice with lower upfront bps
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId2);
        uint256 fundedAmount2 = bullaFactoring.fundInvoice(invoiceId2, factorerChosenUpfrontBps, address(0));
        vm.stopPrank();

        // Verify different funded amounts
        assertGt(fundedAmount1, fundedAmount2, "Higher upfront bps should result in higher funded amount");

        // Verify fee calculations reflect the chosen upfront percentage
        (uint256 fundedAmountGross1, , , , , uint256 netFundedAmount1) = bullaFactoring.calculateTargetFees(invoiceId1, approvedUpfrontBps);
        (uint256 fundedAmountGross2, , , , , uint256 netFundedAmount2) = bullaFactoring.calculateTargetFees(invoiceId2, factorerChosenUpfrontBps);

        assertEq(fundedAmount1, netFundedAmount1);
        assertEq(fundedAmount2, netFundedAmount2);
        assertGt(fundedAmountGross1, fundedAmountGross2);
    }

    function testBullaInvoiceRevertOnInvalidToken() public {
        // Create BullaInvoice with different token
        MockUSDC differentToken = new MockUSDC();
        
        CreateInvoiceParams memory params = CreateInvoiceParams({
            creditor: bob,
            debtor: alice,
            claimAmount: 100000,
            description: "Test Invoice",
            token: address(differentToken), // Different token
            dueBy: block.timestamp + 60 days,
            deliveryDate: 0, // No delivery date for simple invoices
            binding: ClaimBinding.Unbound,
            payerReceivesClaimOnPayment: true,
            lateFeeConfig: InterestConfig({
                interestRateBps: uint16(1000),
                numberOfPeriodsPerYear: uint16(365)
            }),
            impairmentGracePeriod: 15 days,
            depositAmount: 0 // No deposit for simple invoices
        });

        vm.startPrank(bob);
        uint256 invoiceId = bullaInvoice.createInvoice(params);
        vm.stopPrank();

        // Try to approve invoice with mismatched token
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceTokenMismatch()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
    }

    function testBullaInvoiceRevertOnZeroAmount() public {
        // Try to create zero-amount invoice - should fail at BullaInvoice level
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        createInvoice(bob, alice, 0, block.timestamp + 60 days, 1000, 365);
        vm.stopPrank();
    }

    function testBullaInvoiceRevertOnAlreadyFunded() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, 100000, block.timestamp + 60 days, 1000, 365);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Try to approve already funded invoice
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyFunded()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
    }

    function testBullaInvoiceComplexInterestCalculation() public {
        uint256 initialDeposit = 500000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 250000;
        uint256 interestRate = 2400; // 24% APR (high rate for testing)
        uint256 periodsPerYear = 12; // Monthly compounding
        uint256 _dueBy = block.timestamp + 180 days; // 6 months

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward to different payment times and verify interest calculations
        uint256[] memory paymentTimes = new uint256[](3);
        paymentTimes[0] = 60 days;  // 2 months early
        paymentTimes[1] = 120 days; // 1 month early  
        paymentTimes[2] = 180 days; // On time

        for (uint256 i = 0; i < paymentTimes.length; i++) {
            vm.warp(block.timestamp + paymentTimes[i]);
            
            (, uint256 trueInterest, , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);
            
            // Earlier payments should have lower true interest and higher kickback
            assertGt(trueInterest, 0, "True interest should be positive");
            
            if (i > 0) {
                // Reset time for next iteration
                vm.warp(block.timestamp - paymentTimes[i]);
            }
        }
    }

    function testBullaInvoicePoolGainOnlyFromPrincipalNotPenalties() public {
        uint256 initialDeposit = 400000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 principalAmount = 100000;
        uint256 _dueBy = block.timestamp + 30 days;
        
        // Create two invoices with same principal amount
        vm.startPrank(bob);
        // Invoice 1: With interest rate (will generate penalty fees when paid late)
        uint256 invoiceId1 = createInvoice(bob, alice, principalAmount, _dueBy, 1800, 365); // 18% APR
        
        // Invoice 2: Without interest rate (no penalty fees)
        uint256 invoiceId2 = createInvoice(bob, alice, principalAmount, _dueBy, 0, 365); // 0% APR
        vm.stopPrank();

        // Both invoices get the same factoring terms from underwriter
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, minDays, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        // Fund both invoices with same terms
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId1);
        uint256 fundedAmount1 = bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId2);
        uint256 fundedAmount2 = bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();

        // Verify both invoices were funded with the same amount (same principal, same terms)
        assertEq(fundedAmount1, fundedAmount2, "Both invoices should have same funded amount");

        // Fast forward past due date (invoice 1 will accrue penalties, invoice 2 won't)
        vm.warp(block.timestamp + 60 days); // 30 days overdue

        // Get invoice details before payment
        IInvoiceProviderAdapterV2.Invoice memory invoice1 = invoiceAdapterBulla.getInvoiceDetails(invoiceId1);
        IInvoiceProviderAdapterV2.Invoice memory invoice2 = invoiceAdapterBulla.getInvoiceDetails(invoiceId2);

        // Verify that invoice 1 has accrued penalty interest but invoice 2 hasn't
        assertGt(invoice1.invoiceAmount, principalAmount, "Invoice 1 should have accrued penalty interest");
        assertEq(invoice2.invoiceAmount, principalAmount, "Invoice 2 should not have accrued any interest");

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();

        // Pay both invoices (invoice 1 pays more due to penalties, but pool gain should be the same)
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), invoice1.invoiceAmount);
        bullaInvoice.payInvoice(invoiceId1, invoice1.invoiceAmount);
        
        asset.approve(address(bullaInvoice), invoice2.invoiceAmount);
        bullaInvoice.payInvoice(invoiceId2, invoice2.invoiceAmount);
        vm.stopPrank();

        // Reconcile both payments
        bullaFactoring.reconcileActivePaidInvoices();

        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();
        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase from both payments");

        // Check that pool gained the same amount from both invoices
        uint256 gain1 = bullaFactoring.paidInvoicesGain(invoiceId1);
        uint256 gain2 = bullaFactoring.paidInvoicesGain(invoiceId2);

        assertEq(gain1, gain2, "Pool should gain the same amount from both invoices regardless of penalty fees");
        assertGt(gain1, 0, "Pool should have positive gain from factoring");

        // Also verify that spread gains are the same for both invoices
        uint256 spreadGain1 = bullaFactoring.paidInvoicesSpreadGain(invoiceId1);
        uint256 spreadGain2 = bullaFactoring.paidInvoicesSpreadGain(invoiceId2);
        
        assertEq(spreadGain1, spreadGain2, "Pool should have same spread gain from both invoices");

        // The difference in total payment (invoice1 paid more due to penalties) 
        // should NOT affect the pool's gain - those penalties go to the original creditor
        uint256 totalPaymentDifference = invoice1.invoiceAmount - invoice2.invoiceAmount;
        assertGt(totalPaymentDifference, 0, "Invoice 1 should have paid more due to penalty fees");
    }

    function testInterestAccrualTimingPrecision() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, 0, 0);
        vm.stopPrank();

        vm.startPrank(underwriter);
        // Set minDays to 0 to ensure we're testing actual time-based interest
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Test 1: Interest at funding time (0 hours) should be 0
        (, uint256 trueInterest0h, , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);
        assertEq(trueInterest0h, 0, "Interest should be 0 at funding time (0 hours)");

        // Test 2: Interest after 1 hour should still be 0 (same day)
        vm.warp(block.timestamp + 1 hours);
        (, uint256 trueInterest1h, , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);
        assertEq(trueInterest1h, 0, "Interest should be 0 after 1 hour (same day)");

        vm.warp(block.timestamp + 22 hours + 59 minutes);
        (, uint256 trueInterest23h59m, , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);

        // This test documents the current (potentially buggy) behavior
        assertEq(trueInterest23h59m, 0, "Interest should be 0 after 23h59m (still same day)");

        // Test 3: Interest after 24 hours should be non-zero (next day)
        vm.warp(block.timestamp + 1 minutes);
        (, uint256 trueInterest24h, , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);
        assertGt(trueInterest24h, 0, "Interest should be non-zero after 24 hours (next day)");
        
        // Verify that interest increases with more time
        vm.warp(block.timestamp + 24 hours);
        (, uint256 trueInterest48h, , , ) = bullaFactoring.calculateKickbackAmount(invoiceId);
        assertGt(trueInterest48h, trueInterest24h, "Interest should increase after 48 hours");
    }

    function testTargetFeesVsActualFeesAtDueDate() public {
        uint256 initialDeposit = 20000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 10000000;
        uint256 interestRate = 1200; // 12% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days + 1 seconds; // 30 days from now due to floor rounding

        // Create and approve invoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        // Set minDays to 0 to ensure we're testing actual time-based calculations
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0, 0);
        vm.stopPrank();

        // Calculate target fees at funding time (t=0)
        (, uint256 targetAdminFee, uint256 targetInterest, uint256 targetSpreadAmount, uint256 targetProtocolFee, ) = 
            bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);

        // Fund the invoice
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward to due date 30 days, which if target fees are floored, it should be == 30 days + 1
        vm.warp(block.timestamp + 30 days);

        // Calculate actual fees at due date + 1 second
        (, uint256 actualInterest, uint256 actualSpreadAmount, uint256 actualProtocolFee, uint256 actualAdminFee) = 
            bullaFactoring.calculateKickbackAmount(invoiceId);

        // These should be equal since we're comparing fees for the same time period
        // Target fees are calculated based on days until due date at funding time
        // Actual fees are calculated based on actual days elapsed at due date + 1s
        
        // The test documents potential discrepancies
        assertEq(targetInterest, actualInterest, "Target interest should equal actual interest at due date");
        assertEq(targetSpreadAmount, actualSpreadAmount, "Target spread should equal actual spread at due date");
        assertEq(targetProtocolFee, actualProtocolFee, "Target protocol fee should equal actual protocol fee at due date");
        assertEq(targetAdminFee, actualAdminFee, "Target admin fee should equal actual admin fee at due date");
    }

    function testPartialPaymentsConsideredInImpairedInvoiceRealizedGains() public {
        uint256 initialDeposit = 300000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 100000;
        vm.startPrank(address(this)); // Owner
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Record initial price per share for comparison
        uint256 pricePerShareAfterFunding = bullaFactoring.pricePerShare();

        // Make a partial payment before the invoice becomes overdue
        uint256 partialPaymentBeforeImpairment = 25000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPaymentBeforeImpairment);
        bullaInvoice.payInvoice(invoiceId, partialPaymentBeforeImpairment);
        vm.stopPrank();

        // Verify partial payment was recorded
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterPartial = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoiceAfterPartial.paidAmount, partialPaymentBeforeImpairment, "Partial payment should be recorded");
        assertFalse(invoiceAfterPartial.isPaid, "Invoice should not be fully paid yet");

        // Fast forward past due date + grace period to make invoice impaired
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        // Owner impairs the invoice
        vm.startPrank(address(this)); // Owner
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // net funded amount
       (,,,,,,, uint256 fundedAmountNet,,,)= bullaFactoring.approvedInvoices(invoiceId);

        // Verify impairment was recorded
                 (uint256 gainAmount, , ) = bullaFactoring.impairments(invoiceId);
         int256 realizedGainLoss = bullaFactoring.calculateRealizedGainLoss();
         int256 expectedGainLoss = int256(gainAmount) + int256(partialPaymentBeforeImpairment) - int256(fundedAmountNet);
         assertEq(expectedGainLoss, realizedGainLoss, "Partial payment should be considered in realized gain loss");
     }

    function testPartialPaymentBeforeApprovalConsideredInImpairedInvoiceRealizedGains() public {
        uint256 initialDeposit = 300000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 100000;
        vm.startPrank(address(this)); // Owner
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        // Make a small partial payment BEFORE invoice approval
        uint256 partialPaymentBeforeApproval = 15000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPaymentBeforeApproval);
        bullaInvoice.payInvoice(invoiceId, partialPaymentBeforeApproval);
        vm.stopPrank();

        // Verify partial payment was recorded before approval
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterPrePayment = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoiceAfterPrePayment.paidAmount, partialPaymentBeforeApproval, "Pre-approval partial payment should be recorded");
        assertFalse(invoiceAfterPrePayment.isPaid, "Invoice should not be fully paid yet");

        // Now approve and fund the invoice (this should capture the current paid amount as initialPaidAmount)
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Record initial price per share for comparison
        uint256 pricePerShareAfterFunding = bullaFactoring.pricePerShare();

        // Make another partial payment after funding but before impairment
        uint256 partialPaymentAfterFunding = 20000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPaymentAfterFunding);
        bullaInvoice.payInvoice(invoiceId, partialPaymentAfterFunding);
        vm.stopPrank();

        // Verify both payments are recorded
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterSecondPayment = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoiceAfterSecondPayment.paidAmount, partialPaymentBeforeApproval + partialPaymentAfterFunding, 
                "Both partial payments should be recorded");
        assertFalse(invoiceAfterSecondPayment.isPaid, "Invoice should not be fully paid yet");

        // Fast forward past due date + grace period to make invoice impaired
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        // Owner impairs the invoice
        vm.startPrank(address(this)); // Owner
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // Get net funded amount and initial paid amount to verify calculations
        (,,,,,,, uint256 fundedAmountNet,, uint256 initialPaidAmount,) = bullaFactoring.approvedInvoices(invoiceId);

        // Verify that initialPaidAmount captured the pre-approval payment
        assertEq(initialPaidAmount, partialPaymentBeforeApproval, 
                "Initial paid amount should equal pre-approval payment");

        // Verify impairment calculation considers the payments made since funding
        (uint256 gainAmount, , ) = bullaFactoring.impairments(invoiceId);
        int256 realizedGainLoss = bullaFactoring.calculateRealizedGainLoss();
        
        // Expected calculation: gainAmount (from impair reserve) + payments since funding - funded amount
        // Payments since funding = current paid amount - initial paid amount
        uint256 paymentsSinceFunding = invoiceAfterSecondPayment.paidAmount - initialPaidAmount;
        int256 expectedGainLoss = int256(gainAmount) + int256(paymentsSinceFunding) - int256(fundedAmountNet);
        
        assertEq(expectedGainLoss, realizedGainLoss, 
                "Realized gain loss should consider only payments made since funding, not pre-approval payments");
    }

    function testPartialPaymentsConsideredInImpairedInvoiceRealizedGains_NotByFund() public {
        uint256 initialDeposit = 300000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 100000;
        vm.startPrank(address(this)); // Owner
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create, approve, and fund BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Record initial price per share for comparison
        uint256 pricePerShareAfterFunding = bullaFactoring.pricePerShare();

        // Make a partial payment before the invoice becomes overdue
        uint256 partialPaymentBeforeImpairment = 25000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPaymentBeforeImpairment);
        bullaInvoice.payInvoice(invoiceId, partialPaymentBeforeImpairment);
        vm.stopPrank();

        // Verify partial payment was recorded
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterPartial = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoiceAfterPartial.paidAmount, partialPaymentBeforeImpairment, "Partial payment should be recorded");
        assertFalse(invoiceAfterPartial.isPaid, "Invoice should not be fully paid yet");

        // Fast forward past due date + grace period to make invoice impaired
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        // net funded amount
       (,,,,,,, uint256 fundedAmountNet,,,)= bullaFactoring.approvedInvoices(invoiceId);

        // Verify impairment was recorded
                 (uint256 gainAmount, , ) = bullaFactoring.impairments(invoiceId);
         int256 realizedGainLoss = bullaFactoring.calculateRealizedGainLoss();
         int256 expectedGainLoss = int256(gainAmount) + int256(partialPaymentBeforeImpairment) - int256(fundedAmountNet);
         assertEq(expectedGainLoss, realizedGainLoss, "Partial payment should be considered in realized gain loss");
     }

    function testPartialPaymentBeforeApprovalConsideredInImpairedInvoiceRealizedGains_NotByFund() public {
        uint256 initialDeposit = 300000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 100000;
        vm.startPrank(address(this)); // Owner
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000; // 10% APR
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create BullaInvoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        // Make a small partial payment BEFORE invoice approval
        uint256 partialPaymentBeforeApproval = 15000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPaymentBeforeApproval);
        bullaInvoice.payInvoice(invoiceId, partialPaymentBeforeApproval);
        vm.stopPrank();

        // Verify partial payment was recorded before approval
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterPrePayment = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoiceAfterPrePayment.paidAmount, partialPaymentBeforeApproval, "Pre-approval partial payment should be recorded");
        assertFalse(invoiceAfterPrePayment.isPaid, "Invoice should not be fully paid yet");

        // Now approve and fund the invoice (this should capture the current paid amount as initialPaidAmount)
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Record initial price per share for comparison
        uint256 pricePerShareAfterFunding = bullaFactoring.pricePerShare();

        // Make another partial payment after funding but before impairment
        uint256 partialPaymentAfterFunding = 20000;
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), partialPaymentAfterFunding);
        bullaInvoice.payInvoice(invoiceId, partialPaymentAfterFunding);
        vm.stopPrank();

        // Verify both payments are recorded
        IInvoiceProviderAdapterV2.Invoice memory invoiceAfterSecondPayment = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        assertEq(invoiceAfterSecondPayment.paidAmount, partialPaymentBeforeApproval + partialPaymentAfterFunding, 
                "Both partial payments should be recorded");
        assertFalse(invoiceAfterSecondPayment.isPaid, "Invoice should not be fully paid yet");

        // Fast forward past due date + grace period to make invoice impaired
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        // Get net funded amount and initial paid amount to verify calculations
        (,,,,,,, uint256 fundedAmountNet,, uint256 initialPaidAmount,) = bullaFactoring.approvedInvoices(invoiceId);

        // Verify that initialPaidAmount captured the pre-approval payment
        assertEq(initialPaidAmount, partialPaymentBeforeApproval, 
                "Initial paid amount should equal pre-approval payment");

        // Verify impairment calculation considers the payments made since funding
        (uint256 gainAmount, , ) = bullaFactoring.impairments(invoiceId);
        int256 realizedGainLoss = bullaFactoring.calculateRealizedGainLoss();
        
        // Expected calculation: gainAmount (from impair reserve) + payments since funding - funded amount
        // Payments since funding = current paid amount - initial paid amount
        uint256 paymentsSinceFunding = invoiceAfterSecondPayment.paidAmount - initialPaidAmount;
        int256 expectedGainLoss = int256(gainAmount) + int256(paymentsSinceFunding) - int256(fundedAmountNet);
        
        assertEq(expectedGainLoss, realizedGainLoss, 
                "Realized gain loss should consider only payments made since funding, not pre-approval payments");
    }
}
