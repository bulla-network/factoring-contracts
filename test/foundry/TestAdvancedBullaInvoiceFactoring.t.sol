// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import {CreateInvoiceParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {ClaimBinding} from "bulla-contracts-v2/src/types/Types.sol";
import {CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Test at different payment times and verify interest calculations
        uint256[] memory paymentTimes = new uint256[](3);
        paymentTimes[0] = 60 days;  // 2 months early
        paymentTimes[1] = 120 days; // 1 month early  
        paymentTimes[2] = 180 days; // On time

        uint256 previousInterest = 0;

        for (uint256 i = 0; i < paymentTimes.length; i++) {
            vm.warp(block.timestamp + paymentTimes[i]);
            
        (, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee) = bullaFactoring.calculateKickbackAmount(invoiceId);
            
            // Interest should increase with time
            if (i > 0) {
                assertGt(trueInterest, previousInterest, "Interest should increase over time");
            }
            previousInterest = trueInterest;
            
            // Verify all fees are positive
            assertGt(trueInterest, 0, "True interest should be positive");
            assertGt(trueSpreadAmount, 0, "Spread amount should be positive");
            // Protocol fee is now taken upfront at funding time, not part of kickback calculation
            assertGt(trueAdminFee, 0, "Admin fee should be positive");
            
            // Reset time for next iteration
            if (i < paymentTimes.length - 1) {
                vm.warp(block.timestamp - paymentTimes[i]);
            }
        }
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
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
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

        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceAdapterBulla.getInvoiceDetails(invoiceIds[i]);
            
            vm.startPrank(alice);
            asset.approve(address(bullaInvoice), invoice.invoiceAmount);
            bullaInvoice.payInvoice(invoiceIds[i], invoice.invoiceAmount);
            vm.stopPrank();
        }
        
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // Try to fund invoice when insufficient capital
        vm.startPrank(bob);
        IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);


        (uint256 fundedAmountGross, , , , , ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        // fundedAmountGross now includes protocol fee
        // Should revert due to insufficient funds
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringV2_1.InsufficientFunds.selector, initialDeposit, fundedAmountGross));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }
    
    function testBullaInvoiceMultipleFundingAttempts() public{
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
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
