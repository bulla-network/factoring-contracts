// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
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

contract TestPrincipalAmountOverride is CommonSetup {
    
    event InvoiceApproved(uint256 indexed invoiceId, uint256 validUntil, IBullaFactoringV2.FeeParams feeParams);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor, uint256 dueDate, uint16 upfrontBps);
    event InvoiceKickbackAmountSent(uint256 indexed invoiceId, uint256 kickbackAmount, address indexed originalCreditor);

    // Helper function to pay an invoice
    function payInvoice(uint256 invoiceId, uint256 amount) internal {
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), amount);
        bullaClaim.payClaim(invoiceId, amount);
        vm.stopPrank();
    }

    function setUp() public override {
        super.setUp();
        
        // Setup initial deposit for most tests
        vm.startPrank(alice);
        bullaFactoring.deposit(500000, alice); // Large deposit for testing
        vm.stopPrank();
    }

    // ==================== BASIC overrideAmount FUNCTIONALITY TESTS ====================

    function testPrincipalAmountOverride_ZeroOverrideUsesOriginal() public {
        uint256 invoiceAmount = 100000;
        uint256 paidAmount = 20000;
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Pay partially first
        payInvoice(invoiceId, paidAmount);

        // Approve with zero overrideAmount
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        
        // Should use original calculation (invoice amount - paid amount)
        (,,,,,,,,uint256 initialInvoiceValue, uint256 initialPaidAmount,,,) = bullaFactoring.approvedInvoices(invoiceId);
        assertEq(initialInvoiceValue, invoiceAmount - paidAmount);
        assertEq(initialPaidAmount, paidAmount);
    }

    function testPrincipalAmountOverride_HigherThanInvoice() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 150000; // overrideAmount higher than actual invoice
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Should allow overrideAmount higher than invoice amount
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();
        
        (,,,,,,,,uint256 initialInvoiceValue,,,,) = bullaFactoring.approvedInvoices(invoiceId);
        assertEq(initialInvoiceValue, overrideAmount);
        assertTrue(initialInvoiceValue > invoiceAmount);
    }

    function testPrincipalAmountOverride_LowerThanInvoice() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 50000; // Partial factoring
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();
        
        (,,,,,,,,uint256 initialInvoiceValue,,,,) = bullaFactoring.approvedInvoices(invoiceId);
        assertEq(initialInvoiceValue, overrideAmount);
        assertTrue(initialInvoiceValue < invoiceAmount);
    }

    // ==================== FUNDING AMOUNT IMPACT TESTS ====================

    function testPrincipalAmountOverride_FundingCalculations() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 60000; // Factor only 60% of invoice value
        uint16 upfrontPercentage = 8000; // 80%
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();
        
        (uint256 fundedAmountGross, , , , uint256 protocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontPercentage);
        
        // Should be 80% of overrideAmount amount, not original invoice amount
        uint256 expectedGross = ((overrideAmount - protocolFee) * upfrontPercentage) / 10000;
        assertEq(fundedAmountGross, expectedGross);
    }

    function testPrincipalAmountOverride_ActualFunding() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 75000;
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        // Fund the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Verify funding is based on overrideAmount amount
        (,,,,,,uint256 fundedAmountGross, uint256 fundedAmountNet,,,,,) = bullaFactoring.approvedInvoices(invoiceId);
        assertTrue(fundedAmountGross > 0);
        assertTrue(fundedAmountNet > 0);
        assertEq(fundedAmount, fundedAmountNet);
    }

    function testPrincipalAmountOverride_InsufficientFundsWithLargeOverride() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 700000; // Much larger than available funds
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        // Should revert due to insufficient funds
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringV2_1.InsufficientFunds.selector, 500000, 560350));
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }
    
    // ==================== KICKBACK MECHANISM TESTS ====================

    function testPrincipalAmountOverride_KickbackWithHigherOverride() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 120000; // overrideAmount higher than invoice
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        // Fund the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Fast forward and pay invoice
        vm.warp(block.timestamp + 30 days);
        payInvoice(invoiceId, invoiceAmount);
        
        (uint256 kickbackAmount,,,) = bullaFactoring.calculateKickbackAmount(invoiceId);
        
        // Should have kickback since overrideAmount was higher than actual payment
        assertTrue(kickbackAmount > 0);
    }

    function testPrincipalAmountOverride_KickbackWithLowerOverride() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 50000; // Lower overrideAmount
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        // Fund the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Fast forward and pay full invoice
        vm.warp(block.timestamp + 30 days);
        payInvoice(invoiceId, invoiceAmount);
        
        (uint256 kickbackAmount,,,) = bullaFactoring.calculateKickbackAmount(invoiceId);
        
        // Should have significant kickback since payment exceeds overrideAmount
        assertTrue(kickbackAmount > 0);
    }

    // ==================== PRICE PER SHARE IMPACT TESTS ====================

    function testPrincipalAmountOverride_PricePerShareImpact() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 75000;
        
        uint256 initialPrice = bullaFactoring.pricePerShare();
        
        // Create and fund invoice with overrideAmount
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Fast forward and pay
        vm.warp(block.timestamp + 30 days);
        payInvoice(invoiceId, invoiceAmount);
        bullaFactoring.reconcileActivePaidInvoices();
        
        uint256 finalPrice = bullaFactoring.pricePerShare();
        
        // Price should have increased due to gains
        assertTrue(finalPrice > initialPrice);
    }

    function testPrincipalAmountOverride_MultipleInvoicesImpact() public {
        uint256 invoiceAmount = 100000;
        uint256[] memory overrides = new uint256[](3);
        overrides[0] = 50000;  // Lower than invoice
        overrides[1] = 0;      // No overrideAmount
        overrides[2] = 150000; // Higher than invoice
        
        uint256[] memory invoiceIds = new uint256[](3);
        
        // Create and approve invoices with different overrides
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy + i);
            vm.stopPrank();

            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, overrides[i]);
            vm.stopPrank();

            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }
        
        // Verify each invoice uses its respective overrideAmount for calculations
        for (uint i = 0; i < 3; i++) {
            (,,,,,,,,uint256 initialInvoiceValue,,,,) = bullaFactoring.approvedInvoices(invoiceIds[i]);
            if (overrides[i] == 0) {
                assertEq(initialInvoiceValue, invoiceAmount); // Original amount
            } else {
                assertEq(initialInvoiceValue, overrides[i]);
            }
        }
    }

    // ==================== EDGE CASES AND ERROR SCENARIOS ====================

    function testPrincipalAmountOverride_PartiallyPaidInvoice() public {
        uint256 invoiceAmount = 100000;
        uint256 partialPayment = 30000;
        uint256 overrideAmount = 80000;
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Pay partially first
        payInvoice(invoiceId, partialPayment);
        
        // Then approve with overrideAmount
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();
        
        (,,,,,,,,uint256 initialInvoiceValue, uint256 initialPaidAmount,,,) = bullaFactoring.approvedInvoices(invoiceId);
        assertEq(initialInvoiceValue, overrideAmount);
        assertEq(initialPaidAmount, partialPayment);
    }

    function testPrincipalAmountOverride_ZeroInvoiceAmountAfterPayment() public {
        uint256 invoiceAmount = 100000;
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Pay fully
        payInvoice(invoiceId, invoiceAmount);
        
        // Should revert when trying to approve fully paid invoice
        vm.startPrank(underwriter);
        vm.expectRevert();
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 50000);
        vm.stopPrank();
    }

    // ==================== INTEGRATION AND WORKFLOW TESTS ====================

    function testPrincipalAmountOverride_CompleteWorkflow() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 75000;
        
        // 1. Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // 2. Approve with overrideAmount
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();
        
        // 3. Fund
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        assertTrue(fundedAmount > 0);
        
        // 4. Time passes
        vm.warp(block.timestamp + 45 days);
        
        // 5. Pay invoice
        payInvoice(invoiceId, invoiceAmount);
        
        // 6. Reconcile
        bullaFactoring.reconcileActivePaidInvoices();
        
        // Verify all calculations were based on overrideAmount amount
        assertTrue(bullaFactoring.paidInvoicesGain() > 0);
    }

    function testPrincipalAmountOverride_UnfactoringWithOverride() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmount = 60000;
        
        // Create and fund invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Fast forward time
        vm.warp(block.timestamp + 20 days);
        
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Unfactor
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();
        
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Bob should have paid back the funding plus accrued fees
        assertTrue(bobBalanceBefore > bobBalanceAfter);
    }

    // ==================== BUSINESS LOGIC AND RISK MANAGEMENT TESTS ====================

    function testPrincipalAmountOverride_RiskAdjustment() public {
        uint256 invoiceAmount = 100000;
        uint256 conservativeOverrideAmount = 70000; // 70% of face value for risk adjustment
        uint16 higherInterestApr = 1500; // 15% APR for higher risk
        uint16 higherSpreadBps = 2000; // 20% spread for higher risk
        
        // Create invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve with conservative overrideAmount for risk management
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, higherInterestApr, higherSpreadBps, upfrontBps, minDays, conservativeOverrideAmount);
        vm.stopPrank();
        
        // Should allow partial exposure to high-risk invoice
        (,,,,,,,,uint256 initialInvoiceValue,,,,IBullaFactoringV2.FeeParams memory feeParams) = bullaFactoring.approvedInvoices(invoiceId);
        assertEq(initialInvoiceValue, conservativeOverrideAmount);
        assertEq(feeParams.targetYieldBps, higherInterestApr);
        assertEq(feeParams.spreadBps, higherSpreadBps);
    }

    function testPrincipalAmountOverride_CapitalEfficiency() public {
        uint256 availableFunds = 200000;
        uint256 invoiceAmount = 150000;
        uint256 overrideAmount = 100000; // Factor only portion
        
        // Check initial available funds
        uint256 initialAssets = bullaFactoring.totalAssets();
        assertTrue(initialAssets >= availableFunds);
        
        // Create and fund invoice with overrideAmount
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, overrideAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 funded = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Should have remaining capacity for other invoices
        uint256 remainingCapacity = bullaFactoring.totalAssets();
        assertTrue(remainingCapacity > 0);
        assertTrue(funded < invoiceAmount); // Funded less than full invoice
    }

    function testPrincipalAmountOverride_MultiplePartialFactoring() public {
        uint256 invoiceAmount = 100000;
        uint256 overrideAmountoverride1 = 90000; // 90% of first invoice
        uint256 overrideAmountoverride2 = 95000; // 95% of second invoice
        uint16 upfrontBps = 7000;

        // Create two invoices
        vm.startPrank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Approve both with different overrides
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, minDays, overrideAmountoverride1);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, minDays, overrideAmountoverride2);
        vm.stopPrank();

        // Fund both
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        uint256 funded1 = bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        uint256 funded2 = bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();
        
        // Verify funding amounts are proportional to overrides
        assertTrue(funded2 > funded1); // Second invoice should get more funding
        
        // Pay both and verify gains
        vm.warp(block.timestamp + 30 days);
        uint256 gainBefore = bullaFactoring.paidInvoicesGain();
        payInvoice(invoiceId1, invoiceAmount);
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gainAfter1 = bullaFactoring.paidInvoicesGain();
        payInvoice(invoiceId2, invoiceAmount);
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gainAfter2 = bullaFactoring.paidInvoicesGain();
        
        // Both should generate gains
        assertTrue(gainAfter1 > gainBefore);
        assertTrue(gainAfter2 > gainBefore);
        
        // Calculate individual gains for comparison
        uint256 gain1 = gainAfter1 - gainBefore;
        uint256 gain2 = gainAfter2 - gainAfter1;
        
        // Both invoices should generate positive gains
        assertTrue(gain1 > 0);
        assertTrue(gain2 > 0);
    }
} 
