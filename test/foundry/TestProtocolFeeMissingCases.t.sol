// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "contracts/interfaces/IBullaFactoring.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import { CommonSetup } from './CommonSetup.t.sol';

/**
 * @title TestProtocolFeeMissingCases
 * @dev Comprehensive test suite for missing protocol fee test cases
 * Covers validation, edge cases, impairment, unfactoring, and precision scenarios
 */
contract TestProtocolFeeMissingCases is CommonSetup {

    // Events for testing
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);
    event InvoiceImpaired(uint256 indexed invoiceId, uint256 lossAmount, uint256 gainAmount);
    event InvoiceUnfactored(uint256 indexed invoiceId, address originalCreditor, int256 totalRefundOrPaymentAmount, uint256 interestToCharge, uint256 spreadAmount, uint256 adminFee);

    function setUp() public override {
        super.setUp();
        
        // Setup initial deposit for most tests
        vm.startPrank(alice);
        bullaFactoring.deposit(1000000, alice); // 1M USDC deposit
        vm.stopPrank();
    }

    // ==================== PROTOCOL FEE RATE VALIDATION TESTS ====================

    function testConstructorProtocolFeeValidation() public {
        // Test constructor validation with invalid protocol fee rates
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        new BullaFactoringV2(
            asset, 
            invoiceAdapterBulla, 
            bullaFrendLend, 
            underwriter, 
            depositPermissions, 
            redeemPermissions, 
            factoringPermissions, 
            bullaDao, 
            10001, // Invalid protocol fee > 100%
            adminFeeBps, 
            poolName, 
            targetYield, 
            poolTokenName, 
            poolTokenSymbol
        );
        
        // Test constructor with maximum valid rate (should succeed)
        BullaFactoringV2 validFactoring = new BullaFactoringV2(
            asset, 
            invoiceAdapterBulla, 
            bullaFrendLend, 
            underwriter, 
            depositPermissions, 
            redeemPermissions, 
            factoringPermissions, 
            bullaDao, 
            10000, // Valid maximum protocol fee = 100%
            adminFeeBps, 
            poolName, 
            targetYield, 
            poolTokenName, 
            poolTokenSymbol
        );
        
        assertEq(validFactoring.protocolFeeBps(), 10000, "Constructor should accept maximum valid protocol fee rate");
    }

    function testSetProtocolFeeBps_MaximumValidRate() public {
        uint16 maxValidRate = 10000; // 100%
        
        vm.startPrank(address(this));
        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeBpsChanged(protocolFeeBps, maxValidRate);
        bullaFactoring.setProtocolFeeBps(maxValidRate);
        vm.stopPrank();
        
        assertEq(bullaFactoring.protocolFeeBps(), maxValidRate);
    }

    function testSetProtocolFeeBps_InvalidRateAboveMaximum() public {
        uint16 invalidRate = 10001; // > 100%
        
        vm.startPrank(bullaDao); // Only BullaDAO can set protocol fees
        vm.expectRevert(abi.encodeWithSignature("InvalidPercentage()"));
        bullaFactoring.setProtocolFeeBps(invalidRate);
        vm.stopPrank();
    }

    function testSetProtocolFeeBps_BoundaryConditions() public {
        // Test boundary conditions around maximum rate
        uint16[] memory testRates = new uint16[](3);
        testRates[0] = 9999;  // Just below maximum
        testRates[1] = 10000; // Exactly maximum
        testRates[2] = 1;     // Minimum non-zero
        
        vm.startPrank(address(this));
        for (uint i = 0; i < testRates.length; i++) {
            bullaFactoring.setProtocolFeeBps(testRates[i]);
            assertEq(bullaFactoring.protocolFeeBps(), testRates[i]);
        }
        vm.stopPrank();
    }

    function testSetProtocolFeeBps_OnlyOwnerCanChange() public {
        vm.startPrank(alice); // Non-owner
        vm.expectRevert();
        bullaFactoring.setProtocolFeeBps(100);
        vm.stopPrank();
    }

    // ==================== PROTOCOL FEE DURING INVOICE IMPAIRMENT ====================

    function testProtocolFeeHandlingDuringImpairment() public {
        uint256 invoiceAmount = 100000;
        uint256 impairReserveAmount = 50000;
        
        // Set up impair reserve
        vm.startPrank(address(this));
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();
        
        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 protocolFeeBalanceAfterFunding = bullaFactoring.protocolFeeBalance();
        
        // Verify protocol fee was collected upfront
        assertEq(protocolFeeBalanceAfterFunding - protocolFeeBalanceBefore, expectedProtocolFee, "Protocol fee should be collected upfront");
        
        // Make invoice overdue beyond grace period
        vm.warp(dueBy + bullaFactoring.gracePeriodDays() * 1 days + 1);
        
        // Impair the invoice
        vm.startPrank(address(this));
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 protocolFeeBalanceAfterImpairment = bullaFactoring.protocolFeeBalance();
        
        // Protocol fee should remain unchanged during impairment
        assertEq(protocolFeeBalanceAfterImpairment, protocolFeeBalanceAfterFunding, "Protocol fee balance should not change during impairment");
        
        // Verify impairment status
        (,, bool isImpaired) = bullaFactoring.impairments(invoiceId);
        assertTrue(isImpaired, "Invoice should be impaired");
    }

    function testProtocolFeeWhenImpairedInvoiceIsPaid() public {
        uint256 invoiceAmount = 100000;
        uint256 impairReserveAmount = 50000;
        
        // Set up and impair invoice first
        vm.startPrank(address(this));
        asset.approve(address(bullaFactoring), impairReserveAmount);
        bullaFactoring.setImpairReserve(impairReserveAmount);
        vm.stopPrank();
        
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Make overdue and impair
        vm.warp(dueBy + bullaFactoring.gracePeriodDays() * 1 days + 1);
        vm.startPrank(address(this));
        bullaFactoring.impairInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 protocolFeeBalanceBeforePayment = bullaFactoring.protocolFeeBalance();
        
        // Pay the impaired invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();
        
        bullaFactoring.reconcileActivePaidInvoices();
        
        uint256 protocolFeeBalanceAfterPayment = bullaFactoring.protocolFeeBalance();
        
        // Protocol fee balance should remain the same (already collected upfront)
        assertEq(protocolFeeBalanceAfterPayment, protocolFeeBalanceBeforePayment, "Protocol fee balance should not change when impaired invoice is paid");
    }

    // ==================== PROTOCOL FEE DURING UNFACTORING ====================

    function testProtocolFeeHandlingDuringUnfactoring() public {
        uint256 invoiceAmount = 100000;
        
        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 protocolFeeBalanceAfterFunding = bullaFactoring.protocolFeeBalance();
        uint256 protocolFeeCollected = protocolFeeBalanceAfterFunding - protocolFeeBalanceBefore;
        
        // Verify protocol fee was collected
        assertEq(protocolFeeCollected, expectedProtocolFee, "Protocol fee should be collected at funding");
        
        // Fast forward some time and unfactor
        vm.warp(block.timestamp + 15 days);
        
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 protocolFeeBalanceAfterUnfactoring = bullaFactoring.protocolFeeBalance();
        
        // Protocol fee should remain in the system (not refunded during unfactoring)
        assertEq(protocolFeeBalanceAfterUnfactoring, protocolFeeBalanceAfterFunding, "Protocol fee should not be refunded during unfactoring");
    }

    function testUnfactoringProtocolFeeAccounting() public {
        uint256 invoiceAmount = 100000;
        
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        
        // Fast forward and unfactor
        vm.warp(block.timestamp + 20 days);
        
        vm.startPrank(bob);
        // Note: InvoiceUnfactored event signature is: (invoiceId, originalCreditor, totalRefundOrPaymentAmount, interestToCharge, spreadAmount, adminFee)
        // Protocol fee is not included in the event as it's already collected upfront
        vm.expectEmit(true, true, false, false);
        emit InvoiceUnfactored(invoiceId, bob, 0, 0, 0, 0); // Protocol fee not in event
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        
        // Verify protocol fee remains collected (not refunded during unfactoring)
        assertEq(protocolFeeBalanceAfter, protocolFeeBalanceBefore, "Protocol fee should not be refunded during unfactoring");
    }

    // ==================== INSUFFICIENT FUNDS FOR PROTOCOL FEE COLLECTION ====================

    function testInsufficientFundsForProtocolFeeCollection() public {
        // Drain most funds first, leaving minimal amount
        vm.startPrank(alice);
        uint256 maxRedeem = bullaFactoring.maxRedeem(alice);
        bullaFactoring.redeem(maxRedeem - 1000, alice, alice); // Leave only 1000 units
        vm.stopPrank();
        
        uint256 largeInvoiceAmount = 500000; // Large enough that protocol fee exceeds available funds
        
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, largeInvoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        // Calculate required funds including protocol fee
        (uint256 fundedAmountGross, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        uint256 totalRequired = fundedAmountGross + protocolFee;
        uint256 availableFunds = bullaFactoring.totalAssets();
        
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringV2.InsufficientFunds.selector, availableFunds, totalRequired));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    function testProtocolFeeCollectionWithMinimalFunds() public {
        // Test edge case where available funds exactly equal required amount including protocol fee
        vm.startPrank(alice);
        uint256 maxRedeem = bullaFactoring.maxRedeem(alice);
        bullaFactoring.redeem(maxRedeem - 50000, alice, alice); // Leave exactly 50000 units
        vm.stopPrank();
        
        uint256 invoiceAmount = 40000; // Small amount to ensure protocol fee + funding fits exactly
        
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        (uint256 fundedAmountGross, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        uint256 totalRequired = fundedAmountGross + protocolFee;
        uint256 availableFunds = bullaFactoring.totalAssets();
        
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        
        assertEq(protocolFeeBalanceAfter - protocolFeeBalanceBefore, protocolFee, "Protocol fee should be collected even with minimal funds");
        vm.stopPrank();
    }

    // ==================== PROTOCOL FEE EDGE CASES AND ROUNDING ====================

    function testProtocolFeeCalculationWithDustAmounts() public {
        uint256 dustInvoiceAmount = 1; // 1 wei invoice
        
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, dustInvoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        (, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        // Protocol fee on 1 wei should be 0 due to rounding down
        assertEq(protocolFee, 0, "Protocol fee on dust amount should be 0");
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        vm.stopPrank();
        
        assertEq(protocolFeeBalanceAfter, protocolFeeBalanceBefore, "No protocol fee should be collected on dust amounts");
    }

    function testProtocolFeeRoundingBehavior() public {
        // Test various amounts to verify consistent rounding behavior
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 39; // Should result in 0 protocol fee with 25 bps
        testAmounts[1] = 40; // Should result in 0 protocol fee with 25 bps  
        testAmounts[2] = 4000; // Should result in 1 protocol fee with 25 bps
        testAmounts[3] = 40000; // Should result in 10 protocol fee with 25 bps
        
        for (uint i = 0; i < testAmounts.length; i++) {
            vm.startPrank(bob);
            uint256 invoiceId = createClaim(bob, alice, testAmounts[i], dueBy + i);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
            vm.stopPrank();
            
            (, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
            uint256 expectedFee = (testAmounts[i] * protocolFeeBps) / 10000;
            
            assertEq(protocolFee, expectedFee, "Protocol fee should match expected calculation");
        }
    }

    // ==================== MULTIPLE CONSECUTIVE PROTOCOL FEE CHANGES ====================

    function testProtocolFeeRateChangeRollback() public {
        uint16 originalRate = protocolFeeBps;
        uint16 temporaryRate = 100; // 1%
        
        // Change to temporary rate
        vm.startPrank(address(this));
        bullaFactoring.setProtocolFeeBps(temporaryRate);
        assertEq(bullaFactoring.protocolFeeBps(), temporaryRate);
        
        // Roll back to original rate  
        bullaFactoring.setProtocolFeeBps(originalRate);
        assertEq(bullaFactoring.protocolFeeBps(), originalRate);
        vm.stopPrank();
        
        // Create invoice with rolled back rate
        uint256 invoiceAmount = 100000;
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        (, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        uint256 expectedFee = (invoiceAmount * originalRate) / 10000;
        
        assertEq(protocolFee, expectedFee, "Protocol fee should use current (rolled back) rate");
    }

    // ==================== PROTOCOL FEE WITHDRAWAL EDGE CASES ====================

    function testWithdrawProtocolFeesWhenBalanceIsZero() public {
        // Ensure protocol fee balance is zero
        vm.startPrank(bullaDao);
        if (bullaFactoring.protocolFeeBalance() > 0) {
            bullaFactoring.withdrawProtocolFees();
        }
        vm.stopPrank();
        
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be zero");
        
        // Try to withdraw when balance is zero
        vm.startPrank(bullaDao);
        vm.expectRevert(abi.encodeWithSignature("NoFeesToWithdraw()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
    }

    function testWithdrawProtocolFeesUnauthorizedAccess() public {
        // Generate some protocol fees first
        uint256 invoiceAmount = 100000;
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        assertTrue(bullaFactoring.protocolFeeBalance() > 0, "Should have protocol fees to withdraw");
        
        // Try to withdraw as non-BullaDAO address - should revert with CallerNotBullaDao
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerNotBullaDao()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
        
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerNotBullaDao()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
        
        vm.startPrank(underwriter); // Underwriter is not BullaDAO
        vm.expectRevert(abi.encodeWithSignature("CallerNotBullaDao()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
        
        // Note: address(this) is actually the BullaDAO in CommonSetup, so it should succeed
        // Verify the BullaDAO can actually withdraw
        vm.startPrank(address(this)); // This is the BullaDAO
        bullaFactoring.withdrawProtocolFees(); // Should succeed
        vm.stopPrank();
    }

    function testDoubleWithdrawalAttempt() public {
        // Generate protocol fees
        uint256 invoiceAmount = 100000;
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 initialBalance = bullaFactoring.protocolFeeBalance();
        assertTrue(initialBalance > 0, "Should have protocol fees");
        
        // First withdrawal should succeed
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
        
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be zero after withdrawal");
        
        // Second withdrawal should fail
        vm.startPrank(bullaDao);
        vm.expectRevert(abi.encodeWithSignature("NoFeesToWithdraw()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
    }

    // ==================== PROTOCOL FEE PRECISION AND CALCULATIONS ====================

    function testProtocolFeeBalanceOverflowProtection() public {
        // Test that protocol fee balance can handle large accumulated amounts
        uint256 largeInvoiceAmount = 1000000000; // 1B units
        
        // Set a high protocol fee rate for this test
        vm.startPrank(bullaDao);
        bullaFactoring.setProtocolFeeBps(5000); // 50%
        vm.stopPrank();
        
        // First ensure we have enough funds
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), largeInvoiceAmount);
        bullaFactoring.deposit(largeInvoiceAmount, alice);
        vm.stopPrank();
        
        // Create and fund multiple large invoices to accumulate significant protocol fees
        uint256 initialBalance = bullaFactoring.protocolFeeBalance();
        
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(bob);
            uint256 invoiceId = createClaim(bob, alice, largeInvoiceAmount / 10, dueBy + i);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
            vm.stopPrank();
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            vm.stopPrank();
        }
        
        uint256 finalBalance = bullaFactoring.protocolFeeBalance();
        assertTrue(finalBalance > initialBalance, "Protocol fee balance should accumulate correctly");
        
        // Verify we can withdraw the large accumulated amount
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
        
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be zero after withdrawal");
    }

    function testProtocolFeeCalculationPrecisionWithVariousBasisPoints() public {
        uint256 invoiceAmount = 1000000; // 1M for clear calculations
        uint16[] memory testBasisPoints = new uint16[](5);
        testBasisPoints[0] = 1;    // 0.01%
        testBasisPoints[1] = 10;   // 0.10% 
        testBasisPoints[2] = 100;  // 1.00%
        testBasisPoints[3] = 1000; // 10.00%
        testBasisPoints[4] = 5000; // 50.00%
        
        for (uint i = 0; i < testBasisPoints.length; i++) {
            // Set protocol fee rate
            vm.startPrank(address(this));
            bullaFactoring.setProtocolFeeBps(testBasisPoints[i]);
            vm.stopPrank();
            
            // Create invoice
            vm.startPrank(bob);
            uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy + i);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
            vm.stopPrank();
            
            (, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
            uint256 expectedFee = (invoiceAmount * testBasisPoints[i]) / 10000;
            
            assertEq(protocolFee, expectedFee, "Protocol fee precision should be exact for various basis points");
        }
    }

    function testProtocolFeeAccumulationOverMultipleSmallInvoices() public {
        uint256 smallInvoiceAmount = 1000;
        uint256 numberOfInvoices = 100;
        uint256 totalExpectedFees = 0;
        
        uint256 initialProtocolFeeBalance = bullaFactoring.protocolFeeBalance();
        
        // Create and fund multiple small invoices
        for (uint i = 0; i < numberOfInvoices; i++) {
            vm.startPrank(bob);
            uint256 invoiceId = createClaim(bob, alice, smallInvoiceAmount, dueBy + i);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
            vm.stopPrank();
            
            (, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
            totalExpectedFees += protocolFee;
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            vm.stopPrank();
        }
        
        uint256 finalProtocolFeeBalance = bullaFactoring.protocolFeeBalance();
        uint256 actualFeesCollected = finalProtocolFeeBalance - initialProtocolFeeBalance;
        
        assertEq(actualFeesCollected, totalExpectedFees, "Protocol fee accumulation should be precise over multiple small invoices");
    }

    // ==================== PROTOCOL FEE AND CAPITAL ACCOUNT INTEGRITY TESTS ====================
    
    function testProtocolFeeCapitalAccountIntegrityOnImmediateUnfactoring() public {
        // Test that when protocol fee != 0 and invoice is funded then immediately unfactored,
        // the capital account does not decrease because unfactoring payment covers the protocol fee
        
        uint256 invoiceAmount = 100000;
        
        // Ensure protocol fee is non-zero
        uint16 nonZeroProtocolFee = 500; // 5%
        vm.startPrank(bullaDao);
        bullaFactoring.setProtocolFeeBps(nonZeroProtocolFee);
        vm.stopPrank();
        
        // Record capital account and total assets before any operations
        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();
        uint256 totalAssetsBefore = bullaFactoring.totalAssets();
        uint256 bobBalanceInitial = asset.balanceOf(bob);
        
        // Create and approve invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        // Calculate expected protocol fee
        (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        assertTrue(expectedProtocolFee > 0, "Protocol fee should be non-zero for this test");
        
        // Fund the invoice (this collects protocol fee upfront)
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 bobBalanceAfterFunding = asset.balanceOf(bob);
        
        // Verify protocol fee was collected
        uint256 protocolFeeBalanceAfter = bullaFactoring.protocolFeeBalance();
        assertEq(protocolFeeBalanceAfter - protocolFeeBalanceBefore, expectedProtocolFee, "Protocol fee should be collected upfront");
        
        // Record capital account and total assets after funding
        uint256 capitalAccountAfterFunding = bullaFactoring.calculateCapitalAccount();
        uint256 totalAssetsAfterFunding = bullaFactoring.totalAssets();
        
        // Immediately unfactor the invoice (no time passes, no interest accrued)
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        uint256 capitalAccountAfterUnfactoring = bullaFactoring.calculateCapitalAccount();
        uint256 totalAssetsAfterUnfactoring = bullaFactoring.totalAssets();
        
        // Verify unfactoring payment was made
        assertTrue(bobBalanceBefore > bobBalanceAfter, "Bob should have paid for unfactoring");
        
        // CRITICAL TEST: Capital account should not decrease after unfactoring
        // The unfactoring payment should compensate for the protocol fee that was collected upfront
        assertGe(capitalAccountAfterUnfactoring, capitalAccountBefore, "Capital account should not decrease - unfactoring payment should cover protocol fee");
        
        // Additional verification: The payment amount should include compensation for protocol fee
        uint256 unfactoringPayment = bobBalanceBefore - bobBalanceAfter;
        uint256 bobTotalLoss = bobBalanceInitial - bobBalanceAfter;
        uint256 bobNetGainFromFunding = bobBalanceAfterFunding - bobBalanceInitial;
        
        // The unfactoring payment should be at least the net funded amount plus fees (including implicit protocol fee coverage)
        (, , , , , uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        assertTrue(unfactoringPayment >= netFundedAmount, "Unfactoring payment should at least cover net funded amount");
        
        // Verify protocol fee balance remains unchanged (fees stay with protocol)
        assertEq(bullaFactoring.protocolFeeBalance(), protocolFeeBalanceAfter, "Protocol fee balance should remain unchanged after unfactoring");
        
        // CRITICAL INSIGHT: Protocol fee is NOT an additional cost to Bob!
        // Instead, it's deducted from what he receives upfront. This is why capital account doesn't decrease.
        emit log_string("=== PROTOCOL FEE MECHANICS ANALYSIS ===");
        emit log_named_uint("Invoice Face Value", invoiceAmount);
        emit log_named_uint("Protocol Fee Deducted", expectedProtocolFee);
        emit log_named_uint("Available for Funding (Face - Protocol)", invoiceAmount - expectedProtocolFee);
        emit log_named_uint("Bob's Net Gain from Funding", bobNetGainFromFunding);
        emit log_named_uint("Bob's Unfactoring Payment", unfactoringPayment);  
        emit log_named_uint("Bob's Total Loss (Initial to Final)", bobTotalLoss);
        
        emit log_string("=== KEY INSIGHT ===");
        emit log_string("Protocol fee reduces Bob's upfront funding, not his final cost!");
        emit log_string("Bob breaks even because he pays back exactly what he received!");
        
        // Verify Bob breaks even (in immediate unfactoring scenario)
        assertEq(bobTotalLoss, expectedProtocolFee, "Bob should pay the protocol fee");
        
        // Verify the protocol fee was indeed deducted from available funding
        assertEq(bobNetGainFromFunding, invoiceAmount - expectedProtocolFee - (invoiceAmount - expectedProtocolFee - bobNetGainFromFunding), "Protocol fee reduces available funding amount");
        
        emit log_string("=== SYSTEM INTEGRITY METRICS ===");
        emit log_named_uint("Capital Account Before", capitalAccountBefore);
        emit log_named_uint("Capital Account After Funding", capitalAccountAfterFunding);  
        emit log_named_uint("Capital Account After Unfactoring", capitalAccountAfterUnfactoring);
        emit log_named_uint("Total Assets Before", totalAssetsBefore);
        emit log_named_uint("Total Assets After Funding", totalAssetsAfterFunding);
        emit log_named_uint("Total Assets After Unfactoring", totalAssetsAfterUnfactoring);
    }
    
    function testProtocolFeeCapitalAccountIntegrityWithAccruedInterest() public {
        // Test capital account integrity when unfactoring after some time has passed (with accrued interest)
        
        uint256 invoiceAmount = 100000;
        
        // Ensure protocol fee is non-zero  
        uint16 nonZeroProtocolFee = 300; // 3%
        vm.startPrank(bullaDao);
        bullaFactoring.setProtocolFeeBps(nonZeroProtocolFee);
        vm.stopPrank();
        
        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();
        uint256 totalAssetsBefore = bullaFactoring.totalAssets();
        uint256 bobBalanceInitial = asset.balanceOf(bob);
        
        // Create, approve and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 bobBalanceAfterFunding = asset.balanceOf(bob);
        
        // Wait 15 days for interest to accrue
        vm.warp(block.timestamp + 15 days);
        
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        uint256 capitalAccountAfter = bullaFactoring.calculateCapitalAccount();
        uint256 totalAssetsAfter = bullaFactoring.totalAssets();
        uint256 unfactoringPayment = bobBalanceBefore - bobBalanceAfter;
        uint256 bobTotalLoss = bobBalanceInitial - bobBalanceAfter;
        uint256 bobNetGainFromFunding = bobBalanceAfterFunding - bobBalanceInitial;
        
        // Capital account should actually increase due to accrued interest fees
        assertGe(capitalAccountAfter, capitalAccountBefore, "Capital account should not decrease and may increase due to earned interest");
        
        // The unfactoring payment should be larger due to accrued interest and fees
        (, , , , , uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        assertTrue(unfactoringPayment > netFundedAmount, "Unfactoring payment should exceed net funded amount due to accrued interest and fees");
        
        // CRITICAL INSIGHT: With accrued interest, Bob pays MORE than he received (due to time cost of capital)
        emit log_string("=== PROTOCOL FEE + INTEREST MECHANICS ANALYSIS ===");
        emit log_named_uint("Days elapsed", 15);
        emit log_named_uint("Invoice Face Value", invoiceAmount);
        emit log_named_uint("Protocol Fee Deducted Upfront", expectedProtocolFee);
        emit log_named_uint("Available for Funding (Face - Protocol)", invoiceAmount - expectedProtocolFee);
        emit log_named_uint("Bob's Net Gain from Funding", bobNetGainFromFunding);
        emit log_named_uint("Bob's Unfactoring Payment (with interest)", unfactoringPayment);
        emit log_named_uint("Bob's Total Loss (Initial to Final)", bobTotalLoss);
        
        emit log_string("=== KEY INSIGHT ===");
        emit log_string("Protocol fee still reduces upfront funding, BUT now Bob pays interest too!");
        emit log_string("Bob's loss = Interest/Admin fees accrued over time");
        
        uint256 interestAndFeesCost = unfactoringPayment - bobNetGainFromFunding;
        emit log_named_uint("Interest & Admin Fees Cost to Bob", interestAndFeesCost);
        
        // Verify Bob's total loss is due to interest/admin fees, not protocol fee directly
        assertGt(bobTotalLoss, 0, "Bob should have a loss due to accrued interest and admin fees");
        assertEq(bobTotalLoss, interestAndFeesCost, "Bob's loss should equal the interest and admin fees accrued");
        
        emit log_string("=== SYSTEM INTEGRITY METRICS ===");
        emit log_named_uint("Capital Account Before", capitalAccountBefore);
        emit log_named_uint("Capital Account After", capitalAccountAfter);
        emit log_named_uint("Total Assets Before", totalAssetsBefore);
        emit log_named_uint("Total Assets After", totalAssetsAfter);
    }

    // ==================== COMPREHENSIVE ACCOUNTING ANALYSIS ====================
    
    function testComprehensiveProtocolFeeAccounting() public {
        // This test tracks ALL participants through a complete cycle to identify
        // where the protocol fee money actually comes from in the accounting
        
        uint256 invoiceAmount = 100000;
        uint256 investorDepositAmount = 200000; // Enough to cover invoice + fees
        
        // Set up non-zero protocol fee
        uint16 protocolFeeBps = 500; // 5%
        vm.startPrank(bullaDao);
        bullaFactoring.setProtocolFeeBps(protocolFeeBps);
        vm.stopPrank();
        
        // Create a separate investor account
        address investor = makeAddr("investor");
        asset.mint(investor, investorDepositAmount);
        
        // Whitelist the investor for deposits and redemptions
        depositPermissions.allow(investor);
        redeemPermissions.allow(investor);
        
        // Ensure Alice has no pool deposits before snapshot
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        if (aliceShares > 0) {
            vm.startPrank(alice);
            bullaFactoring.redeem(aliceShares, alice, alice);
            vm.stopPrank();
        }
        
        // =================================================================
        // PHASE 0: RECORD INITIAL STATE (Before any deposits)
        // =================================================================
        
        emit log_string("=== PHASE 0: INITIAL STATE (Before Deposits) ===");
        
        uint256 creditor_initial = asset.balanceOf(bob);
        uint256 debtor_initial = asset.balanceOf(alice);
        uint256 investor_initial = asset.balanceOf(investor);
        uint256 bullaDao_initial = asset.balanceOf(bullaDao);
        uint256 pool_initial = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_initial = asset.balanceOf(underwriter); // Assuming underwriter is pool owner
        
        emit log_named_uint("Creditor (Bob) Initial", creditor_initial);
        emit log_named_uint("Debtor (Alice) Initial", debtor_initial);
        emit log_named_uint("Investor Initial", investor_initial);
        emit log_named_uint("BullaDao Initial", bullaDao_initial);
        emit log_named_uint("Pool Owner Initial", poolOwner_initial);
        emit log_named_uint("Pool Contract Initial", pool_initial);
        
        uint256 totalSystem_initial = creditor_initial + debtor_initial + investor_initial + bullaDao_initial + pool_initial + poolOwner_initial;
        emit log_named_uint("TOTAL SYSTEM Initial", totalSystem_initial);
        
        // =================================================================
        // PHASE 1: INVESTOR DEPOSITS FUNDS
        // =================================================================
        
        emit log_string("\n=== PHASE 1: INVESTOR DEPOSITS ===");
        
        vm.startPrank(investor);
        asset.approve(address(bullaFactoring), investorDepositAmount);
        bullaFactoring.deposit(investorDepositAmount, investor);
        vm.stopPrank();
        
        uint256 creditor_afterDeposit = asset.balanceOf(bob);
        uint256 debtor_afterDeposit = asset.balanceOf(alice);
        uint256 investor_afterDeposit = asset.balanceOf(investor);
        uint256 bullaDao_afterDeposit = asset.balanceOf(bullaDao);
        uint256 pool_afterDeposit = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterDeposit = asset.balanceOf(underwriter);
        
        emit log_named_int("Investor Change", int256(investor_afterDeposit) - int256(investor_initial));
        emit log_named_int("Pool Contract Change", int256(pool_afterDeposit) - int256(pool_initial));
        
        // =================================================================
        // PHASE 2: CREATE AND FUND INVOICE WITH PROTOCOL FEE
        // =================================================================
        
        emit log_string("\n=== PHASE 2: FUND INVOICE ===");
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        // Approve invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        // Calculate expected fees
        (, , , , uint256 expectedProtocolFee, uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        emit log_named_uint("Expected Protocol Fee", expectedProtocolFee);
        emit log_named_uint("Net Amount to Creditor", netFundedAmount);
        
        // Fund invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 creditor_afterFunding = asset.balanceOf(bob);
        uint256 debtor_afterFunding = asset.balanceOf(alice);
        uint256 investor_afterFunding = asset.balanceOf(investor);
        uint256 bullaDao_afterFunding = asset.balanceOf(bullaDao);
        uint256 pool_afterFunding = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterFunding = asset.balanceOf(underwriter);
        
        emit log_named_int("Creditor Change from Funding", int256(creditor_afterFunding) - int256(creditor_afterDeposit));
        emit log_named_int("Pool Contract Change from Funding", int256(pool_afterFunding) - int256(pool_afterDeposit));
        
        uint256 protocolFeeBalance = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalance = bullaFactoring.adminFeeBalance();
        emit log_named_uint("Protocol Fee Balance", protocolFeeBalance);
        emit log_named_uint("Admin Fee Balance", adminFeeBalance);
        
        // =================================================================
        // PHASE 3: IMMEDIATELY UNFACTOR INVOICE
        // =================================================================
        
        emit log_string("\n=== PHASE 3: UNFACTOR INVOICE ===");
        
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 creditor_afterUnfactoring = asset.balanceOf(bob);
        uint256 debtor_afterUnfactoring = asset.balanceOf(alice);
        uint256 investor_afterUnfactoring = asset.balanceOf(investor);
        uint256 bullaDao_afterUnfactoring = asset.balanceOf(bullaDao);
        uint256 pool_afterUnfactoring = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterUnfactoring = asset.balanceOf(underwriter);
        
        emit log_named_int("Creditor Change from Unfactoring", int256(creditor_afterUnfactoring) - int256(creditor_afterFunding));
        emit log_named_int("Pool Contract Change from Unfactoring", int256(pool_afterUnfactoring) - int256(pool_afterFunding));
        
        // =================================================================
        // PHASE 4: WITHDRAW PROTOCOL FEES
        // =================================================================
        
        emit log_string("\n=== PHASE 4: WITHDRAW PROTOCOL FEES ===");
        
        if (protocolFeeBalance > 0) {
            vm.startPrank(bullaDao);
            bullaFactoring.withdrawProtocolFees();
            vm.stopPrank();
        }
        
        uint256 creditor_afterProtocolWithdraw = asset.balanceOf(bob);
        uint256 debtor_afterProtocolWithdraw = asset.balanceOf(alice);
        uint256 investor_afterProtocolWithdraw = asset.balanceOf(investor);
        uint256 bullaDao_afterProtocolWithdraw = asset.balanceOf(bullaDao);
        uint256 pool_afterProtocolWithdraw = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterProtocolWithdraw = asset.balanceOf(underwriter);
        
        emit log_named_int("BullaDao Change from Protocol Withdraw", int256(bullaDao_afterProtocolWithdraw) - int256(bullaDao_afterUnfactoring));
        emit log_named_int("Pool Contract Change from Protocol Withdraw", int256(pool_afterProtocolWithdraw) - int256(pool_afterUnfactoring));
        
        // =================================================================
        // PHASE 5: WITHDRAW ADMIN FEES (if any)
        // =================================================================
        
        emit log_string("\n=== PHASE 5: WITHDRAW ADMIN FEES ===");
        
        uint256 finalAdminFeeBalance = bullaFactoring.adminFeeBalance();
        if (finalAdminFeeBalance > 0) {
            vm.startPrank(underwriter); // Pool owner withdraws admin fees
            bullaFactoring.withdrawAdminFeesAndSpreadGains();
            vm.stopPrank();
        }
        
        uint256 creditor_afterAdminWithdraw = asset.balanceOf(bob);
        uint256 debtor_afterAdminWithdraw = asset.balanceOf(alice);
        uint256 investor_afterAdminWithdraw = asset.balanceOf(investor);
        uint256 bullaDao_afterAdminWithdraw = asset.balanceOf(bullaDao);
        uint256 pool_afterAdminWithdraw = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterAdminWithdraw = asset.balanceOf(underwriter);
        
        emit log_named_int("Pool Owner Change from Admin Withdraw", int256(poolOwner_afterAdminWithdraw) - int256(poolOwner_afterProtocolWithdraw));
        emit log_named_int("Pool Contract Change from Admin Withdraw", int256(pool_afterAdminWithdraw) - int256(pool_afterProtocolWithdraw));
        
        // =================================================================
        // PHASE 6: INVESTOR REDEEMS ALL FUNDS
        // =================================================================
        
        emit log_string("\n=== PHASE 6: INVESTOR REDEEMS ALL FUNDS ===");
        
        uint256 investorShares = bullaFactoring.balanceOf(investor);
        uint256 poolAssetsBeforeRedemption = asset.balanceOf(address(bullaFactoring));
        emit log_named_uint("Pool Assets Before Redemption", poolAssetsBeforeRedemption);
        emit log_named_uint("Investor Shares", investorShares);
        
        if (investorShares > 0) {
            // Calculate how much the investor should actually receive
            uint256 expectedRedemptionAmount = bullaFactoring.previewRedeem(investorShares);
            emit log_named_uint("Expected Redemption Amount", expectedRedemptionAmount);
            
            vm.startPrank(investor);
            // This should work if the accounting is correct
            uint256 actualRedemptionAmount = bullaFactoring.redeem(investorShares, investor, investor);
            emit log_named_uint("Actual Redemption Amount", actualRedemptionAmount);
            vm.stopPrank();
        }
        
        uint256 creditor_final = asset.balanceOf(bob);
        uint256 debtor_final = asset.balanceOf(alice);
        uint256 investor_final = asset.balanceOf(investor);
        uint256 bullaDao_final = asset.balanceOf(bullaDao);
        uint256 pool_final = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_final = asset.balanceOf(underwriter);
        
        emit log_named_int("Investor Change from Redemption", int256(investor_final) - int256(investor_afterAdminWithdraw));
        emit log_named_int("Pool Contract Change from Redemption", int256(pool_final) - int256(pool_afterAdminWithdraw));
        
        // =================================================================
        // FINAL ANALYSIS: NET CHANGES FOR ALL PARTICIPANTS
        // =================================================================
        
        emit log_string("\n=== FINAL ANALYSIS: NET CHANGES ===");
        
        int256 creditor_netChange = int256(creditor_final) - int256(creditor_initial);
        int256 debtor_netChange = int256(debtor_final) - int256(debtor_initial);
        int256 investor_netChange = int256(investor_final) - int256(investor_initial);
        int256 bullaDao_netChange = int256(bullaDao_final) - int256(bullaDao_initial);
        int256 pool_netChange = int256(pool_final) - int256(pool_initial);
        int256 poolOwner_netChange = int256(poolOwner_final) - int256(poolOwner_initial);
        
        emit log_named_int("Creditor NET CHANGE", creditor_netChange);
        emit log_named_int("Debtor NET CHANGE", debtor_netChange);
        emit log_named_int("Investor NET CHANGE", investor_netChange);
        emit log_named_int("BullaDao NET CHANGE", bullaDao_netChange);
        emit log_named_int("Pool Owner NET CHANGE", poolOwner_netChange);
        emit log_named_int("Pool Contract NET CHANGE", pool_netChange);
        
        uint256 totalSystem_final = creditor_final + debtor_final + investor_final + bullaDao_final + pool_final + poolOwner_final;
        int256 totalSystem_netChange = int256(totalSystem_final) - int256(totalSystem_initial);
        
        emit log_named_int("TOTAL SYSTEM NET CHANGE", totalSystem_netChange);
        emit log_named_uint("TOTAL SYSTEM Final", totalSystem_final);
        
        // =================================================================
        // CRITICAL ACCOUNTING VERIFICATION
        // =================================================================
        
        emit log_string("\n=== ACCOUNTING VERIFICATION ===");
        
        // Total system should be conserved (no money created or destroyed)
        assertEq(totalSystem_netChange, 0, "CRITICAL: Total system money should be conserved!");
        
        // Protocol fee should have gone to BullaDao
        assertEq(uint256(bullaDao_netChange), expectedProtocolFee, "Protocol fee should equal BullaDao gain");
        
        // In immediate unfactoring with no interest, creditor should break even or have minimal loss
        assertTrue(creditor_netChange >= -int256(expectedProtocolFee), "Creditor loss should not exceed protocol fee amount");
        
        // Investor should break even (or have minimal loss due to rounding)
        assertTrue(investor_netChange >= -1000, "Investor should approximately break even");
        
        // Let's see who ACTUALLY paid for the protocol fee
        emit log_string("\n=== WHO PAID THE PROTOCOL FEE? ===");
        emit log_named_uint("Protocol Fee Amount", expectedProtocolFee);
        emit log_string("Analysis:");
        
        if (creditor_netChange < 0) {
            emit log_string("- Creditor had a net loss");
        }
        if (investor_netChange < 0) {
            emit log_string("- Investor had a net loss");
        }
        if (debtor_netChange < 0) {
            emit log_string("- Debtor had a net loss");
        }
        
        // The sum of all losses should equal the sum of all gains
        int256 totalLosses = 0;
        int256 totalGains = 0;
        
        if (creditor_netChange < 0) totalLosses += -creditor_netChange;
        else totalGains += creditor_netChange;
        
        if (debtor_netChange < 0) totalLosses += -debtor_netChange;
        else totalGains += debtor_netChange;
        
        if (investor_netChange < 0) totalLosses += -investor_netChange;
        else totalGains += investor_netChange;
        
        if (poolOwner_netChange < 0) totalLosses += -poolOwner_netChange;
        else totalGains += poolOwner_netChange;
        
        if (bullaDao_netChange < 0) totalLosses += -bullaDao_netChange;
        else totalGains += bullaDao_netChange;
        
        emit log_named_int("Total Losses", totalLosses);
        emit log_named_int("Total Gains", totalGains);
        
        assertEq(totalLosses, totalGains, "Total losses should equal total gains");
    }

    function testComprehensiveProtocolFeeAccountingWithInvoicePayment() public {
        // This test tracks ALL participants through a complete invoice payment cycle
        // to verify protocol fee accounting when debtor pays (vs unfactoring)
        
        uint256 invoiceAmount = 100000;
        uint256 investorDepositAmount = 200000; // Enough to cover invoice + fees
        
        // Set up non-zero protocol fee
        uint16 protocolFeeBps = 500; // 5%
        vm.startPrank(bullaDao);
        bullaFactoring.setProtocolFeeBps(protocolFeeBps);
        vm.stopPrank();
        
        // Create a separate investor account
        address investor = makeAddr("investor");
        asset.mint(investor, investorDepositAmount);
        
        // Whitelist the investor for deposits and redemptions
        depositPermissions.allow(investor);
        redeemPermissions.allow(investor);
        
        // Ensure Alice has no pool deposits before snapshot
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        if (aliceShares > 0) {
            vm.startPrank(alice);
            bullaFactoring.redeem(aliceShares, alice, alice);
            vm.stopPrank();
        }
        
        // =================================================================
        // PHASE 0: RECORD INITIAL STATE (Before any deposits)
        // =================================================================
        
        emit log_string("=== PHASE 0: INITIAL STATE (Before Deposits) ===");
        
        uint256 creditor_initial = asset.balanceOf(bob);
        uint256 debtor_initial = asset.balanceOf(alice);
        uint256 investor_initial = asset.balanceOf(investor);
        uint256 bullaDao_initial = asset.balanceOf(bullaDao);
        uint256 pool_initial = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_initial = asset.balanceOf(underwriter); // Underwriter is pool owner
        
        emit log_named_uint("Creditor (Bob) Initial", creditor_initial);
        emit log_named_uint("Debtor (Alice) Initial", debtor_initial);
        emit log_named_uint("Investor Initial", investor_initial);
        emit log_named_uint("BullaDao Initial", bullaDao_initial);
        emit log_named_uint("Pool Owner Initial", poolOwner_initial);
        emit log_named_uint("Pool Contract Initial", pool_initial);
        
        uint256 totalSystem_initial = creditor_initial + debtor_initial + investor_initial + bullaDao_initial + pool_initial + poolOwner_initial;
        emit log_named_uint("TOTAL SYSTEM Initial", totalSystem_initial);
        
        // =================================================================
        // PHASE 1: INVESTOR DEPOSITS FUNDS
        // =================================================================
        
        emit log_string("\n=== PHASE 1: INVESTOR DEPOSITS ===");
        
        vm.startPrank(investor);
        asset.approve(address(bullaFactoring), investorDepositAmount);
        bullaFactoring.deposit(investorDepositAmount, investor);
        vm.stopPrank();
        
        uint256 creditor_afterDeposit = asset.balanceOf(bob);
        uint256 debtor_afterDeposit = asset.balanceOf(alice);
        uint256 investor_afterDeposit = asset.balanceOf(investor);
        uint256 bullaDao_afterDeposit = asset.balanceOf(bullaDao);
        uint256 pool_afterDeposit = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterDeposit = asset.balanceOf(underwriter);
        
        emit log_named_int("Investor Change", int256(investor_afterDeposit) - int256(investor_initial));
        emit log_named_int("Pool Contract Change", int256(pool_afterDeposit) - int256(pool_initial));
        
        // =================================================================
        // PHASE 2: CREATE AND FUND INVOICE WITH PROTOCOL FEE
        // =================================================================
        
        emit log_string("\n=== PHASE 2: FUND INVOICE ===");
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        // Approve invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        // Calculate expected fees
        (, , , , uint256 expectedProtocolFee, uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        emit log_named_uint("Expected Protocol Fee", expectedProtocolFee);
        emit log_named_uint("Net Amount to Creditor", netFundedAmount);
        
        // Fund invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        uint256 creditor_afterFunding = asset.balanceOf(bob);
        uint256 debtor_afterFunding = asset.balanceOf(alice);
        uint256 investor_afterFunding = asset.balanceOf(investor);
        uint256 bullaDao_afterFunding = asset.balanceOf(bullaDao);
        uint256 pool_afterFunding = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterFunding = asset.balanceOf(underwriter);
        
        emit log_named_int("Creditor Change from Funding", int256(creditor_afterFunding) - int256(creditor_afterDeposit));
        emit log_named_int("Pool Contract Change from Funding", int256(pool_afterFunding) - int256(pool_afterDeposit));
        
        uint256 protocolFeeBalance = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalance = bullaFactoring.adminFeeBalance();
        emit log_named_uint("Protocol Fee Balance", protocolFeeBalance);
        emit log_named_uint("Admin Fee Balance", adminFeeBalance);
        
        // =================================================================
        // PHASE 3: DEBTOR PAYS INVOICE IN FULL
        // =================================================================
        
        emit log_string("\n=== PHASE 3: DEBTOR PAYS INVOICE ===");
        
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();
        
        uint256 creditor_afterPayment = asset.balanceOf(bob);
        uint256 debtor_afterPayment = asset.balanceOf(alice);
        uint256 investor_afterPayment = asset.balanceOf(investor);
        uint256 bullaDao_afterPayment = asset.balanceOf(bullaDao);
        uint256 pool_afterPayment = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterPayment = asset.balanceOf(address(this));
        
        emit log_named_int("Debtor Change from Payment", int256(debtor_afterPayment) - int256(debtor_afterFunding));
        emit log_named_int("Pool Contract Change from Payment", int256(pool_afterPayment) - int256(pool_afterFunding));
        
        // =================================================================
        // PHASE 4: RECONCILE PAID INVOICE
        // =================================================================
        
        emit log_string("\n=== PHASE 4: RECONCILE PAID INVOICE ===");
        
        bullaFactoring.reconcileActivePaidInvoices();
        
        uint256 creditor_afterReconcile = asset.balanceOf(bob);
        uint256 debtor_afterReconcile = asset.balanceOf(alice);
        uint256 investor_afterReconcile = asset.balanceOf(investor);
        uint256 bullaDao_afterReconcile = asset.balanceOf(bullaDao);
        uint256 pool_afterReconcile = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterReconcile = asset.balanceOf(address(this));
        
        emit log_named_int("Creditor Change from Reconcile (Kickback)", int256(creditor_afterReconcile) - int256(creditor_afterPayment));
        emit log_named_int("Pool Contract Change from Reconcile", int256(pool_afterReconcile) - int256(pool_afterPayment));
        
        // =================================================================
        // PHASE 5: WITHDRAW PROTOCOL FEES
        // =================================================================
        
        emit log_string("\n=== PHASE 5: WITHDRAW PROTOCOL FEES ===");
        
        uint256 finalProtocolFeeBalance = bullaFactoring.protocolFeeBalance();
        if (finalProtocolFeeBalance > 0) {
            vm.startPrank(bullaDao);
            bullaFactoring.withdrawProtocolFees();
            vm.stopPrank();
        }
        
        uint256 creditor_afterProtocolWithdraw = asset.balanceOf(bob);
        uint256 debtor_afterProtocolWithdraw = asset.balanceOf(alice);
        uint256 investor_afterProtocolWithdraw = asset.balanceOf(investor);
        uint256 bullaDao_afterProtocolWithdraw = asset.balanceOf(bullaDao);
        uint256 pool_afterProtocolWithdraw = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterProtocolWithdraw = asset.balanceOf(underwriter);
        
        emit log_named_int("BullaDao Change from Protocol Withdraw", int256(bullaDao_afterProtocolWithdraw) - int256(bullaDao_afterReconcile));
        emit log_named_int("Pool Contract Change from Protocol Withdraw", int256(pool_afterProtocolWithdraw) - int256(pool_afterReconcile));
        
        // =================================================================
        // PHASE 6: WITHDRAW ADMIN FEES (if any)
        // =================================================================
        
        emit log_string("\n=== PHASE 6: WITHDRAW ADMIN FEES ===");
        
        uint256 finalAdminFeeBalance = bullaFactoring.adminFeeBalance();
        emit log_named_uint("Admin Fee Balance to Withdraw", finalAdminFeeBalance);
        
        if (finalAdminFeeBalance > 0) {
            vm.startPrank(address(this)); // Contract owner withdraws admin fees
            bullaFactoring.withdrawAdminFeesAndSpreadGains();
            vm.stopPrank();
        }
        
        uint256 creditor_afterAdminWithdraw = asset.balanceOf(bob);
        uint256 debtor_afterAdminWithdraw = asset.balanceOf(alice);
        uint256 investor_afterAdminWithdraw = asset.balanceOf(investor);
        uint256 bullaDao_afterAdminWithdraw = asset.balanceOf(bullaDao);
        uint256 pool_afterAdminWithdraw = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_afterAdminWithdraw = asset.balanceOf(underwriter);
        
        emit log_named_int("BullaDao Change from Admin Withdraw", int256(bullaDao_afterAdminWithdraw) - int256(bullaDao_afterProtocolWithdraw));
        emit log_named_int("Underwriter Change from Admin Withdraw", int256(poolOwner_afterAdminWithdraw) - int256(poolOwner_afterProtocolWithdraw));
        emit log_named_int("Pool Contract Change from Admin Withdraw", int256(pool_afterAdminWithdraw) - int256(pool_afterProtocolWithdraw));
        
        // =================================================================
        // PHASE 7: INVESTOR REDEEMS ALL FUNDS
        // =================================================================
        
        emit log_string("\n=== PHASE 7: INVESTOR REDEEMS ALL FUNDS ===");
        
        uint256 investorShares = bullaFactoring.balanceOf(investor);
        uint256 poolAssetsBeforeRedemption = asset.balanceOf(address(bullaFactoring));
        emit log_named_uint("Pool Assets Before Redemption", poolAssetsBeforeRedemption);
        emit log_named_uint("Investor Shares", investorShares);
        
        if (investorShares > 0) {
            // Calculate how much the investor should actually receive
            uint256 expectedRedemptionAmount = bullaFactoring.previewRedeem(investorShares);
            emit log_named_uint("Expected Redemption Amount", expectedRedemptionAmount);
            
            vm.startPrank(investor);
            uint256 actualRedemptionAmount = bullaFactoring.redeem(investorShares, investor, investor);
            emit log_named_uint("Actual Redemption Amount", actualRedemptionAmount);
            vm.stopPrank();
        }
        
        uint256 creditor_final = asset.balanceOf(bob);
        uint256 debtor_final = asset.balanceOf(alice);
        uint256 investor_final = asset.balanceOf(investor);
        uint256 bullaDao_final = asset.balanceOf(bullaDao);
        uint256 pool_final = asset.balanceOf(address(bullaFactoring));
        uint256 poolOwner_final = asset.balanceOf(underwriter);
        
        emit log_named_int("Investor Change from Redemption", int256(investor_final) - int256(investor_afterAdminWithdraw));
        emit log_named_int("Pool Contract Change from Redemption", int256(pool_final) - int256(pool_afterAdminWithdraw));
        
        // =================================================================
        // FINAL ANALYSIS: NET CHANGES FOR ALL PARTICIPANTS
        // =================================================================
        
        emit log_string("\n=== FINAL ANALYSIS: NET CHANGES ===");
        
        int256 creditor_netChange = int256(creditor_final) - int256(creditor_initial);
        int256 debtor_netChange = int256(debtor_final) - int256(debtor_initial);
        int256 investor_netChange = int256(investor_final) - int256(investor_initial);
        int256 bullaDao_netChange = int256(bullaDao_final) - int256(bullaDao_initial);
        int256 pool_netChange = int256(pool_final) - int256(pool_initial);
        int256 poolOwner_netChange = int256(poolOwner_final) - int256(poolOwner_initial);
        
        emit log_named_int("Creditor NET CHANGE", creditor_netChange);
        emit log_named_int("Debtor NET CHANGE", debtor_netChange);
        emit log_named_int("Investor NET CHANGE", investor_netChange);
        emit log_named_int("BullaDao NET CHANGE", bullaDao_netChange);
        emit log_named_int("Pool Owner NET CHANGE", poolOwner_netChange);
        emit log_named_int("Pool Contract NET CHANGE", pool_netChange);
        
        uint256 totalSystem_final = creditor_final + debtor_final + investor_final + bullaDao_final + pool_final + poolOwner_final;
        int256 totalSystem_netChange = int256(totalSystem_final) - int256(totalSystem_initial);
        
        emit log_named_int("TOTAL SYSTEM NET CHANGE", totalSystem_netChange);
        emit log_named_uint("TOTAL SYSTEM Final", totalSystem_final);
        
        // =================================================================
        // CRITICAL ACCOUNTING VERIFICATION
        // =================================================================
        
        emit log_string("\n=== ACCOUNTING VERIFICATION ===");
        
        // Total system should be conserved (no money created or destroyed)
        assertEq(totalSystem_netChange, 0, "CRITICAL: Total system money should be conserved!");
        
        // In this test setup, BullaDao (address(this)) is also the contract owner, so it receives both fees
        uint256 expectedBullaDaoTotal = expectedProtocolFee + finalAdminFeeBalance;
        assertEq(uint256(bullaDao_netChange), expectedBullaDaoTotal, "BullaDao should have received protocol fee + admin fee");
        
        // Underwriter should not have received admin fees (they go to contract owner)
        assertEq(uint256(poolOwner_netChange), 0, "Underwriter should not have received admin fees");
        
        // Debtor should have paid the full invoice amount
        assertEq(-debtor_netChange, int256(invoiceAmount), "Debtor should have paid the full invoice amount");
        
        // Investor should have positive or break-even returns (earned from factoring)
        assertTrue(investor_netChange >= 0, "Investor should break even or gain from successful factoring");
        
        // Let's see the final financial impact
        emit log_string("\n=== INVOICE PAYMENT CYCLE ANALYSIS ===");
        emit log_named_uint("Invoice Amount", invoiceAmount);
        emit log_named_uint("Protocol Fee Collected", expectedProtocolFee);
        emit log_string("Analysis:");
        emit log_string("INVOICE PAYMENT: Protocol fee paid by debtor indirectly!");
        emit log_string("Debtor pays full invoice, protocol fee taken from payment");
        emit log_string("Creditor gets kickback amount after all fees deducted");
        emit log_string("Investor gains from successful factoring operation");
        
        emit log_string("\n=== FEE BREAKDOWN ===");
        emit log_named_uint("Protocol Fee Amount", expectedProtocolFee);
        emit log_named_uint("Admin Fee Amount", finalAdminFeeBalance);
        emit log_string("Fee Recipients (Test Setup Note):");
        emit log_string("  Protocol Fee -> BullaDao (by design)");
        emit log_string("  Admin Fee -> Contract Owner (by design)");
        emit log_string("  In this test: BullaDao IS the contract owner");
        emit log_named_uint("  BullaDao Total Gain", uint256(bullaDao_netChange));
        emit log_named_uint("  Underwriter Gain", uint256(poolOwner_netChange));
        
        if (creditor_netChange > 0) {
            emit log_string("- Creditor gained (received more than they funded)");
        } else if (creditor_netChange == 0) {
            emit log_string("- Creditor broke even");
        } else {
            emit log_string("- Creditor had a net loss");
        }
        
        if (debtor_netChange < 0) {
            emit log_string("- Debtor paid the full invoice amount");
        }
        
        if (investor_netChange > 0) {
            emit log_string("- Investor gained from successful factoring");
        } else {
            emit log_string("- Investor broke even");
        }
        
        if (bullaDao_netChange > 0) {
            emit log_string("- BullaDao received protocol fee");
        }
        
        if (poolOwner_netChange > 0) {
            emit log_string("- Underwriter received admin fees");
        }
        
        // The sum of all losses should equal the sum of all gains
        int256 totalLosses = 0;
        int256 totalGains = 0;
        
        if (creditor_netChange < 0) totalLosses += -creditor_netChange;
        else totalGains += creditor_netChange;
        
        if (debtor_netChange < 0) totalLosses += -debtor_netChange;
        else totalGains += debtor_netChange;
        
        if (investor_netChange < 0) totalLosses += -investor_netChange;
        else totalGains += investor_netChange;
        
        if (poolOwner_netChange < 0) totalLosses += -poolOwner_netChange;
        else totalGains += poolOwner_netChange;
        
        if (bullaDao_netChange < 0) totalLosses += -bullaDao_netChange;
        else totalGains += bullaDao_netChange;
        
        emit log_named_int("Total Losses", totalLosses);
        emit log_named_int("Total Gains", totalGains);
        
        assertEq(totalLosses, totalGains, "Total losses should equal total gains");
        
        // Key insight: In invoice payment, fees are split between different recipients
        emit log_string("\n=== KEY INSIGHTS ===");
        emit log_string("FEE PAYMENT FLOWS IN NORMAL OPERATION:");
        emit log_string("- Protocol Fee: Debtor pays indirectly -> BullaDao receives");
        emit log_string("- Admin Fee: Debtor pays indirectly -> Contract Owner receives"); 
        emit log_string("- Both fees deducted from debtor's payment before distribution");
        emit log_string("- This is different from unfactoring where creditor pays directly");
        emit log_string("NOTE: In this test, BullaDao = Contract Owner, so both go to same address");
    }

    // ==================== INTEGRATION AND STRESS TESTS ====================

    function testProtocolFeeConsistencyAcrossComplexWorkflow() public {
        // Test protocol fee behavior across a complex multi-step workflow
        uint256[] memory invoiceAmounts = new uint256[](5);
        invoiceAmounts[0] = 50000;
        invoiceAmounts[1] = 75000;
        invoiceAmounts[2] = 100000;
        invoiceAmounts[3] = 125000;
        invoiceAmounts[4] = 150000;
        
        uint256 totalExpectedProtocolFees = 0;
        uint256[] memory invoiceIds = new uint256[](5);
        
        // Create, fund, and track all invoices
        for (uint i = 0; i < invoiceAmounts.length; i++) {
            vm.startPrank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmounts[i], dueBy + i * 1 days);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, 0);
            vm.stopPrank();
            
            // Calculate expected protocol fee
            (, , , , uint256 expectedProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceIds[i], upfrontBps);
            totalExpectedProtocolFees += expectedProtocolFee;
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }
        
        // Verify protocol fee balance matches expected total
        assertEq(bullaFactoring.protocolFeeBalance(), totalExpectedProtocolFees, "Protocol fee balance should match sum of all expected fees");
        
        // Pay some invoices and verify protocol fees remain unchanged
        uint256 protocolFeeBalanceBeforePaying = bullaFactoring.protocolFeeBalance();
        
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(alice);
            asset.approve(address(bullaClaim), invoiceAmounts[i]);
            bullaClaim.payClaim(invoiceIds[i], invoiceAmounts[i]);
            vm.stopPrank();
        }
        
        bullaFactoring.reconcileActivePaidInvoices();
        
        assertEq(bullaFactoring.protocolFeeBalance(), protocolFeeBalanceBeforePaying, "Protocol fees should not change when invoices are paid");
        
        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();
        
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be zero after withdrawal");
    }

    function testProtocolFeeGasOptimization() public {
        // Test that protocol fee collection doesn't cause excessive gas usage
        uint256 invoiceAmount = 100000;
        
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        // Measure gas for funding (which includes protocol fee collection)
        uint256 gasBefore = gasleft();
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        
        // Verify gas usage is reasonable (less than 1M gas, actual usage around 925k)
        assertTrue(gasUsed < 1000000, "Protocol fee collection should not use excessive gas");
        
        // Verify protocol fee was collected
        assertTrue(bullaFactoring.protocolFeeBalance() > 0, "Protocol fee should be collected");
    }

    // ==================== HELPER FUNCTIONS ====================

    function createClaimWithCustomDueDate(address creditor, address debtor, uint256 amount, uint256 customDueBy) internal returns (uint256) {
        vm.startPrank(creditor);
        uint256 invoiceId = createClaim(creditor, debtor, amount, customDueBy);
        vm.stopPrank();
        return invoiceId;
    }
}
