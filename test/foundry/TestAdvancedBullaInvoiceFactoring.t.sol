// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import {CreateInvoiceParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {ClaimBinding} from "bulla-contracts-v2/src/types/Types.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/BullaClaim.sol";
import {EIP712Helper} from './utils/EIP712Helper.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "contracts/interfaces/IBullaFactoring.sol";

contract TestAdvancedBullaInvoiceFactoring is CommonSetup {
    
    EIP712Helper public sigHelper;

    error ERC20InsufficientBalance(address, uint256, uint256);
    
    // Events to test
    event InvoiceImpaired(uint256 indexed invoiceId, uint256 lossAmount, uint256 gainAmount);
    event InvoiceUnfactored(uint256 indexed invoiceId, address indexed originalCreditor, int256 refundOrPaymentAmount, uint256 interest, uint256 spreadAmount, uint256 protocolFee, uint256 adminFee);

    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));
        
        // Add factoring pool to feeExemption whitelist
        feeExemptionWhitelist.allow(address(bullaFactoring));

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

        // Test at different payment times and verify interest calculations
        uint256[] memory paymentTimes = new uint256[](3);
        paymentTimes[0] = 60 days;  // 2 months early
        paymentTimes[1] = 120 days; // 1 month early  
        paymentTimes[2] = 180 days; // On time

        uint256 previousInterest = 0;

        for (uint256 i = 0; i < paymentTimes.length; i++) {
            vm.warp(block.timestamp + paymentTimes[i]);
            
            (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee) = bullaFactoring.calculateKickbackAmount(invoiceId);
            
            // Interest should increase with time
            if (i > 0) {
                assertGt(trueInterest, previousInterest, "Interest should increase over time");
            }
            previousInterest = trueInterest;
            
            // Verify all fees are positive
            assertGt(trueInterest, 0, "True interest should be positive");
            assertGt(trueSpreadAmount, 0, "Spread amount should be positive");
            assertGt(trueProtocolFee, 0, "Protocol fee should be positive");
            assertGt(trueAdminFee, 0, "Admin fee should be positive");
            
            // Reset time for next iteration
            if (i < paymentTimes.length - 1) {
                vm.warp(block.timestamp - paymentTimes[i]);
            }
        }
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
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Let invoice become overdue (beyond grace period)
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        // Owner impairs the invoice
        vm.startPrank(address(this)); // Owner
        vm.expectEmit(true, false, false, true);
        emit InvoiceImpaired(invoiceId, fundedAmount, impairReserveAmount / 2);
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // Verify impairment
        (uint256 gainAmount, uint256 lossAmount, bool isImpaired) = bullaFactoring.impairments(invoiceId);
        assertTrue(isImpaired);
        assertEq(lossAmount, fundedAmount);
        assertEq(gainAmount, impairReserveAmount / 2);

        // Verify capital account reflects impairment
        uint256 capitalAccountAfter = bullaFactoring.calculateCapitalAccount();
        int256 expectedChange = int256(gainAmount) - int256(lossAmount);
        assertEq(int256(capitalAccountAfter) - int256(capitalAccountBefore), expectedChange);
    }

    function testBullaInvoiceImpairmentThenPayment() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 50000;
        vm.startPrank(address(this));
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000;
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

        // Let invoice become overdue and impair it
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days + 1);

        vm.startPrank(address(this));
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // Now debtor pays the invoice after impairment
        vm.warp(block.timestamp + 10 days);

        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        
        vm.startPrank(alice);
        asset.approve(address(bullaInvoice), invoice.invoiceAmount);
        bullaInvoice.payInvoice(invoiceId, invoice.invoiceAmount);
        vm.stopPrank();

        // Reconcile and verify the impairment is reversed
        bullaFactoring.reconcileActivePaidInvoices();

        // Verify invoice is no longer marked as impaired
        (, , bool isImpaired) = bullaFactoring.impairments(invoiceId);
        assertFalse(isImpaired);
    }

    function testBullaInvoiceMultipleInvoicesWithDifferentInterestRates() public {
        uint256 initialDeposit = 1000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256[] memory interestRates = new uint256[](3);
        interestRates[0] = 500;  // 5% APR
        interestRates[1] = 1200; // 12% APR
        interestRates[2] = 2000; // 20% APR

        uint256[] memory invoiceIds = new uint256[](3);
        uint256 _dueBy = block.timestamp + 90 days;

        // Create multiple invoices with different interest rates
        for (uint256 i = 0; i < interestRates.length; i++) {
            vm.startPrank(bob);
            invoiceIds[i] = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRates[i], 365);
            vm.stopPrank();

            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays);
            vm.stopPrank();

            vm.startPrank(bob);
            IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fast forward and pay all invoices
        vm.warp(block.timestamp + 60 days);

        uint256 totalAccruedProfitsBefore = bullaFactoring.calculateAccruedProfits();
        assertGt(totalAccruedProfitsBefore, 0);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceIds[i]);
            
            vm.startPrank(alice);
            asset.approve(address(bullaInvoice), invoice.invoiceAmount);
            bullaInvoice.payInvoice(invoiceIds[i], invoice.invoiceAmount);
            vm.stopPrank();
        }

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 pricePerShareAfter = bullaFactoring.pricePerShare();

        assertGt(pricePerShareAfter, pricePerShareBefore, "Price per share should increase after all invoices are paid");
    }

    function testBullaInvoiceFactoringCapacityLimits() public {
        uint256 initialDeposit = 100000; // Limited deposit
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 largeInvoiceAmount = 150000; // More than available capital
        uint256 interestRate = 1000;
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create large invoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, largeInvoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
        vm.stopPrank();

        // Try to fund invoice when insufficient capital
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);


        (,,,,,uint256 fundedAmountNet) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        // Should revert due to insufficient funds
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, address(bullaFactoring), initialDeposit, fundedAmountNet));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testBullaInvoiceRedemptionConstraints() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 150000;
        uint256 interestRate = 1000;
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create and fund large invoice
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

        // Try to redeem more than available after funding
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        uint256 maxRedeemableShares = bullaFactoring.maxRedeem(alice);
        uint256 maxWithdrawableAssets = bullaFactoring.maxWithdraw(alice);

        // Max redeemable should be less than total shares due to active invoice
        assertLt(maxRedeemableShares, aliceShares);
        assertLt(maxWithdrawableAssets, initialDeposit);

        // Try to redeem all shares (should fail)
        vm.startPrank(alice);
        vm.expectRevert();
        bullaFactoring.redeem(aliceShares, alice, alice);
        vm.stopPrank();

        // Redeem only what's allowed
        vm.startPrank(alice);
        if (maxRedeemableShares > 0) {
            bullaFactoring.redeem(maxRedeemableShares, alice, alice);
        }
        vm.stopPrank();
    }

    function testBullaInvoiceGracePeriodEdgeCases() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set impair reserve
        uint256 impairReserveAmount = 50000;
        vm.startPrank(address(this));
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000;
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 30 days;

        // Create and fund invoice
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

        // Test impairment exactly at grace period boundary
        vm.warp(block.timestamp + 30 days + bullaFactoring.gracePeriodDays() * 1 days);

        // Should not be impaired yet (exactly at boundary)
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotImpaired()"));
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // Move 1 second past grace period
        vm.warp(block.timestamp + 1);

        // Now should be able to impair
        vm.startPrank(address(this));
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();

        // Verify impairment
        (, , bool isImpaired) = bullaFactoring.impairments(invoiceId);
        assertTrue(isImpaired);
    }

    function testBullaInvoiceMultipleFundingAttempts() public {
        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000;
        uint256 interestRate = 1000;
        uint256 periodsPerYear = 365;
        uint256 _dueBy = block.timestamp + 60 days;

        // Create and approve invoice
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, invoiceAmount, _dueBy, interestRate, periodsPerYear);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays);
        vm.stopPrank();

        // Fund invoice first time
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Try to fund again (should fail)
        vm.startPrank(bob);
        vm.expectRevert(); // Should revert because invoice already owned by factoring contract
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }
} 
