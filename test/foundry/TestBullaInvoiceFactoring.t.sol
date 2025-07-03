// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import {CreateInvoiceParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {InterestComputationState} from "bulla-contracts-v2/src/libraries/CompoundInterestLib.sol";
import {ClaimBinding} from "bulla-contracts-v2/src/types/Types.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/BullaClaim.sol";
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
        vm.stopPrank();

        // Calculate expected fees
        (uint256 fundedAmountGross, uint256 adminFee, uint256 targetInterest, uint256 targetSpreadAmount, uint256 targetProtocolFee, uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);

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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
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
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, approvedUpfrontBps, minDays);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, approvedUpfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Try to approve already funded invoice
        vm.startPrank(underwriter);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyFunded()"));
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward to different payment times and verify interest calculations
        uint256[] memory paymentTimes = new uint256[](3);
        paymentTimes[0] = 60 days;  // 2 months early
        paymentTimes[1] = 120 days; // 1 month early  
        paymentTimes[2] = 180 days; // On time

        for (uint256 i = 0; i < paymentTimes.length; i++) {
            vm.warp(block.timestamp + paymentTimes[i]);
            
            (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee) = bullaFactoring.calculateKickbackAmount(invoiceId);
            
            // Earlier payments should have lower true interest and higher kickback
            assertGt(trueInterest, 0, "True interest should be positive");
            
            if (i > 0) {
                // Reset time for next iteration
                vm.warp(block.timestamp - paymentTimes[i]);
            }
        }
    }
} 
