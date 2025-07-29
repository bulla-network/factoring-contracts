// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "contracts/interfaces/IBullaFactoring.sol";
import {LoanOfferExpired, InvalidTermLength} from '@bulla/contracts-v2/src/BullaFrendLendV2.sol';
import {CreateClaimApprovalType} from '@bulla/contracts-v2/src/types/Types.sol';
import {EIP712Helper} from './utils/EIP712Helper.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Loan} from '@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol';
import {Status} from '@bulla/contracts-v2/src/types/Types.sol';

contract TestLoanOffersWorkflow is CommonSetup {

    EIP712Helper public sigHelper;
    
    event InvoiceFunded(
        uint256 indexed invoiceId,
        uint256 fundedAmount,
        address indexed originalCreditor,
        uint256 invoiceDueDate,
        uint16 upfrontBps
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
    }
    
    // Helper function to get pending loan offers count
    function getPendingLoanOffersCount() internal view returns (uint256) {
        uint256 count = 0;
        try bullaFactoring.pendingLoanOffersIds(count) {
            while (true) {
                try bullaFactoring.pendingLoanOffersIds(count) {
                    count++;
                } catch {
                    break;
                }
            }
        } catch {
            // Array is empty
        }
        return count;
    }
    
    // Helper function to get active invoices count
    function getActiveInvoicesCount() internal view returns (uint256) {
        uint256 count = 0;
        try bullaFactoring.activeInvoices(count) {
            while (true) {
                try bullaFactoring.activeInvoices(count) {
                    count++;
                } catch {
                    break;
                }
            }
        } catch {
            // Array is empty
        }
        return count;
    }

    // ============= ACCESS CONTROL TESTS =============
    
    function testOfferLoan_OnlyUnderwriterCanOffer() public {
        vm.startPrank(alice);
        vm.expectRevert(BullaFactoringV2.CallerNotUnderwriter.selector);
        bullaFactoring.offerLoan(
            bob,           // debtor
            1000,          // targetYieldBps (10%)
            500,           // spreadBps (5%)
            100_000,       // principalAmount
            30 days,       // termLength
            365,           // numberOfPeriodsPerYear
            "Test loan"    // description
        );
        vm.stopPrank();
    }
    
    function testOfferLoan_OwnerCannotCall() public {
        vm.startPrank(address(this)); // Contract owner
        vm.expectRevert(BullaFactoringV2.CallerNotUnderwriter.selector);
        bullaFactoring.offerLoan(
            bob,
            1000,
            500,
            100_000,
            30 days,
            365, // numberOfPeriodsPerYear
            "Test loan"
        );
        vm.stopPrank();
    }
    
    function testOnLoanOfferAccepted_OnlyBullaFrendLendCanCallback() public {
        vm.startPrank(alice);
        vm.expectRevert(BullaFactoringV2.CallerNotBullaFrendLend.selector);
        bullaFactoring.onLoanOfferAccepted(1, 2);
        vm.stopPrank();
        
        vm.startPrank(underwriter);
        vm.expectRevert(BullaFactoringV2.CallerNotBullaFrendLend.selector);
        bullaFactoring.onLoanOfferAccepted(1, 2);
        vm.stopPrank();
    }
    
    function testOnLoanOfferAccepted_UnderwriterCannotCallDirectly() public {
        vm.startPrank(underwriter);
        vm.expectRevert(BullaFactoringV2.CallerNotBullaFrendLend.selector);
        bullaFactoring.onLoanOfferAccepted(999, 123);
        vm.stopPrank();
    }

    // ============= COMPLETE WORKFLOW TESTS =============
    
    function testOfferLoanAndAcceptance_CompleteFlow() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 1000;
        uint16 _spreadBps = 500;
        uint256 termLength = 30 days;
        string memory description = "Test loan offer";
        
        // Record initial state
        uint256 initialPendingCount = getPendingLoanOffersCount();
        uint256 initialActiveCount = getActiveInvoicesCount();
        
        vm.startPrank(underwriter);
        
        // Step 1: Create loan offer
        uint256 loanOfferId = bullaFactoring.offerLoan(
            bob,
            targetYieldBps,
            _spreadBps,
            principalAmount,
            termLength,
            365, // numberOfPeriodsPerYear
            description
        );
        
        vm.stopPrank();
        
        // Verify pending loan offer was created
        assertEq(
            getPendingLoanOffersCount(),
            initialPendingCount + 1,
            "Pending loan offer should be added"
        );
        
        // Verify pending loan offer details
        (
            bool exists,
            uint256 offeredAt,
            uint256 storedPrincipal,
            uint256 storedTermLength,
            IBullaFactoringV2.FeeParams memory feeParams
        ) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertTrue(exists, "Loan offer should exist");
        assertEq(storedPrincipal, principalAmount, "Principal amount should match");
        assertEq(storedTermLength, termLength, "Term length should match");
        assertEq(feeParams.targetYieldBps, targetYieldBps, "Target yield should match");
        assertEq(feeParams.spreadBps, _spreadBps, "Spread should match");
        assertEq(feeParams.upfrontBps, 100_00, "Upfront should be 100%");
        assertEq(feeParams.protocolFeeBps, protocolFeeBps, "Protocol fee should match");
        assertEq(feeParams.adminFeeBps, adminFeeBps, "Admin fee should match");
        assertEq(feeParams.minDaysInterestApplied, 0, "Min days should be 0");
        assertGt(offeredAt, 0, "Offered timestamp should be set");
        
        // Alice deposits to fund the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(principalAmount * 2, alice);
        vm.stopPrank();
        
        // Record balances before loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.expectEmit(true, true, false, true);
        emit InvoiceFunded(
            bullaClaim.currentClaimId() + 1,
            principalAmount,
            address(bullaFactoring),
            block.timestamp + termLength,
            100_00
        );
        
        // Accept loan
        vm.prank(bob);
        uint256 loanId = bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            principalAmount,
            "Factoring contract should have transferred principal amount"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            principalAmount,
            "Bob should have received principal amount"
        );
        
        // Step 3: Verify state after acceptance
        
        // Pending loan offer should be removed
        assertEq(
            getPendingLoanOffersCount(),
            initialPendingCount,
            "Pending loan offer should be removed"
        );
        
        (bool removedExists,,,, ) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertFalse(removedExists, "Loan offer should not exist after acceptance");
        
        // Invoice approval should be created
        (
            bool approved,
            address creditor,
            uint256 validUntil,
            uint256 invoiceDueDate,
            uint256 fundedTimestamp,
            IBullaFactoringV2.FeeParams memory approvalFeeParams,
            uint256 fundedAmountGross,
            uint256 fundedAmountNet,
            uint256 initialInvoiceValue,
            uint256 initialPaidAmount,
            address receiverAddress
        ) = bullaFactoring.approvedInvoices(loanOfferId);
        
        assertTrue(approved, "Invoice should be approved");
        assertEq(creditor, address(bullaFactoring), "Creditor should be factoring contract");
        assertEq(fundedAmountGross, principalAmount, "Funded amount gross should match");
        assertEq(fundedAmountNet, principalAmount, "Funded amount net should match");
        assertEq(initialInvoiceValue, principalAmount, "Initial full amount should match");
        assertEq(initialPaidAmount, 0, "Initial paid amount should be 0");
        assertEq(receiverAddress, address(bullaFactoring), "Receiver address should be factoring contract");
        assertEq(invoiceDueDate, block.timestamp + termLength, "Due date should be calculated correctly");
        assertEq(validUntil, offeredAt, "Valid until should be offered timestamp");
        assertEq(fundedTimestamp, block.timestamp, "Funded timestamp should be current time");
        
        // Fee params should transfer correctly
        assertEq(approvalFeeParams.targetYieldBps, targetYieldBps, "Target yield should transfer");
        assertEq(approvalFeeParams.spreadBps, _spreadBps, "Spread should transfer");
        assertEq(approvalFeeParams.upfrontBps, 100_00, "Upfront should transfer");
        assertEq(approvalFeeParams.protocolFeeBps, protocolFeeBps, "Protocol fee should transfer");
        assertEq(approvalFeeParams.adminFeeBps, adminFeeBps, "Admin fee should transfer");
        assertEq(approvalFeeParams.minDaysInterestApplied, 0, "Min days should transfer");
        
        // Active invoices should be updated
        assertEq(
            getActiveInvoicesCount(),
            initialActiveCount + 1,
            "Active invoices should be incremented"
        );
        
        // Original creditor should be set
        assertEq(
            bullaFactoring.originalCreditors(loanId),
            address(bullaFactoring),
            "Original creditor should be factoring contract"
        );
    }
    
    function testOfferLoanAndAcceptance_StateTransitions() public {
        uint256 principalAmount = 50_000;
        uint16 targetYieldBps = 800;
        uint16 _spreadBps = 200;
        uint256 termLength = 45 days;
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, targetYieldBps, _spreadBps, principalAmount, termLength, 365, "State test");
        vm.stopPrank();
        
        // Verify pending loan offer exists
        (bool existsBefore,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertTrue(existsBefore, "Loan offer should exist before acceptance");
        
        // Accept loan
        uint256 loanId = 54321;
        vm.prank(address(bullaFrendLend));
        bullaFactoring.onLoanOfferAccepted(loanOfferId, loanId);
        
        // Verify pending loan offer is removed
        (bool existsAfter,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertFalse(existsAfter, "Loan offer should not exist after acceptance");
        
        // Verify invoice approval is created
        (bool approved,,,,,,,,,, ) = bullaFactoring.approvedInvoices(loanId);
        assertTrue(approved, "Invoice should be approved after acceptance");
    }
    
    function testOfferLoanAndAcceptance_FeeParamsTransfer() public {
        uint256 principalAmount = 75_000;
        uint16 targetYieldBps = 1200;
        uint16 _spreadBps = 800;
        uint256 termLength = 60 days;
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, targetYieldBps, _spreadBps, principalAmount, termLength, 365, "Fee params test");
        vm.stopPrank();
        
        // Get original fee params
        (,,,, IBullaFactoringV2.FeeParams memory originalFeeParams) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = principalAmount * 2; // Deposit more than needed
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Record balances before loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Accept loan
        vm.prank(bob);
        bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            principalAmount,
            "Factoring contract should have transferred principal amount"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            principalAmount,
            "Bob should have received principal amount"
        );
        
        // Get transferred fee params
        (,,,, , IBullaFactoringV2.FeeParams memory transferredFeeParams,,,,,) = bullaFactoring.approvedInvoices(loanOfferId);
        
        // Verify all fee params transferred correctly
        assertEq(transferredFeeParams.targetYieldBps, originalFeeParams.targetYieldBps, "Target yield should transfer");
        assertEq(transferredFeeParams.spreadBps, originalFeeParams.spreadBps, "Spread should transfer");
        assertEq(transferredFeeParams.upfrontBps, originalFeeParams.upfrontBps, "Upfront should transfer");
        assertEq(transferredFeeParams.protocolFeeBps, originalFeeParams.protocolFeeBps, "Protocol fee should transfer");
        assertEq(transferredFeeParams.adminFeeBps, originalFeeParams.adminFeeBps, "Admin fee should transfer");
        assertEq(transferredFeeParams.minDaysInterestApplied, originalFeeParams.minDaysInterestApplied, "Min days should transfer");
    }
    
    function testOfferLoanAndAcceptance_MultipleLoansCascade() public {
        // Create multiple loan offers
        vm.startPrank(underwriter);
        
        uint256[] memory loanOfferIds = new uint256[](3);
        
        for (uint i = 0; i < 3; i++) {
            loanOfferIds[i] = bullaFactoring.offerLoan(
                bob,
                1000 + uint16(i * 100), // Different yields
                500,
                100_000 + (i * 10_000), // Different amounts
                30 days,
                365, // numberOfPeriodsPerYear
                string(abi.encodePacked("Loan ", vm.toString(i)))
            );
        }
        
        vm.stopPrank();
        
        // Alice makes a deposit to fund the pool
        uint256 totalPrincipal = 300_000 + 30_000; // Sum of all loan amounts
        vm.startPrank(alice);
        bullaFactoring.deposit(totalPrincipal, alice);
        vm.stopPrank();
        
        // Record balances before accepting middle loan (loan index 1)
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 expectedPrincipal = 110_000; // Amount for loan index 1: 100_000 + (1 * 10_000)
        
        // Accept middle loan offer first
        vm.prank(bob);
        bullaFrendLend.acceptLoan(loanOfferIds[1]);
        
        // Record balances after loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers for the accepted loan
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            expectedPrincipal,
            "Factoring contract should have transferred principal amount for loan 1"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            expectedPrincipal,
            "Bob should have received principal amount for loan 1"
        );
        
        // Verify only the accepted offer was removed
        assertEq(getPendingLoanOffersCount(), 2, "Should have 2 pending offers left");
        
        // Verify the specific offer was removed
        (bool removedExists,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferIds[1]);
        assertFalse(removedExists, "Middle loan offer should be removed");
        
        // Verify other offers still exist
        (bool exists0,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferIds[0]);
        (bool exists2,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferIds[2]);
        
        assertTrue(exists0, "First loan offer should still exist");
        assertTrue(exists2, "Third loan offer should still exist");
    }

    // ============= ERROR HANDLING TESTS =============
    
    function testOnLoanOfferAccepted_NonexistentLoanOffer() public {
        vm.prank(address(bullaFrendLend));
        vm.expectRevert(BullaFactoringV2.LoanOfferNotExists.selector);
        bullaFactoring.onLoanOfferAccepted(999, 123);
    }
    
    function testOnLoanOfferAccepted_AlreadyAcceptedLoanOffer() public {
        // Create and accept a loan offer
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "Test");
        vm.stopPrank();
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = 100_000 * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Record balances before loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.prank(bob);
        uint256 loanId = bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            100_000,
            "Factoring contract should have transferred principal amount"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            100_000,
            "Bob should have received principal amount"
        );

        vm.startPrank(underwriter);
        uint256 nextLoanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "Test");
        vm.stopPrank();
        
        // Try to accept the same loan offer again
        vm.prank(address(bullaFrendLend));
        vm.expectRevert(BullaFactoringV2.LoanOfferAlreadyAccepted.selector);
        bullaFactoring.onLoanOfferAccepted(nextLoanOfferId, loanId);
    }
    
    function testOnLoanOfferAccepted_LoanOfferNotFromThisPool() public {
        // Try to accept a loan offer ID that was never created by this pool
        uint256 fakeLoanOfferId = 999999;
        
        vm.prank(address(bullaFrendLend));
        vm.expectRevert(BullaFactoringV2.LoanOfferNotExists.selector);
        bullaFactoring.onLoanOfferAccepted(fakeLoanOfferId, 123);
    }
    
    function testOfferLoanAndAcceptance_ExpiredOfferNotAccepted() public {
        // Get current approval duration to understand expiration timing
        uint256 approvalDuration = bullaFactoring.approvalDuration();
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "Expiration test");
        vm.stopPrank();
        
        // Verify pending loan offer exists
        (bool existsBefore,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertTrue(existsBefore, "Loan offer should exist before expiration");
        
        // Warp time past the expiration
        vm.warp(block.timestamp + approvalDuration + 1);
        
        // BullaFrendLend should not call onLoanOfferAccepted for expired offers
        // This test verifies that the pending loan offer remains in storage 
        // since BullaFrendLend prevents acceptance of expired offers
        (bool existsAfterExpiration,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertTrue(existsAfterExpiration, "Expired loan offer should remain in storage until cleaned up");
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = 100_000 * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Record balances before attempted loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.prank(bob);
        vm.expectRevert(LoanOfferExpired.selector);
        bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after failed loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify no fund transfers occurred due to expiration
        assertEq(
            factoringBalanceAfter,
            factoringBalanceBefore,
            "Factoring contract balance should not change on expired loan"
        );
        assertEq(
            bobBalanceAfter,
            bobBalanceBefore,
            "Bob's balance should not change on expired loan"
        );
    }

    // ============= VALID INPUT TESTS =============
    
    function testOfferLoan_ValidParameters() public {
        uint256 principalAmount = 100_000;
        uint16 targetYieldBps = 1000;
        uint16 _spreadBps = 500;
        uint256 termLength = 30 days;
        string memory description = "Test loan offer";
        
        uint256 initialPendingCount = getPendingLoanOffersCount();
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(
            bob,
            targetYieldBps,
            _spreadBps,
            principalAmount,
            termLength,
            365, // numberOfPeriodsPerYear
            description
        );
        vm.stopPrank();
        
        // Verify pending loan offer was added
        assertEq(
            getPendingLoanOffersCount(),
            initialPendingCount + 1,
            "Pending loan offer should be added"
        );
        
        // Verify pending loan offer details
        (
            bool exists,
            uint256 offeredAt,
            uint256 storedPrincipal,
            uint256 storedTermLength,
            IBullaFactoringV2.FeeParams memory feeParams
        ) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertTrue(exists, "Loan offer should exist");
        assertEq(storedPrincipal, principalAmount, "Principal amount should match");
        assertEq(storedTermLength, termLength, "Term length should match");
        assertGt(offeredAt, 0, "Offered timestamp should be set");
        assertEq(feeParams.targetYieldBps, targetYieldBps, "Target yield should match");
        assertEq(feeParams.spreadBps, _spreadBps, "Spread should match");
    }
    
    function testOfferLoan_ZeroTargetYield() public {
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 0, 500, 100_000, 30 days, 365, "Zero yield test");
        vm.stopPrank();
        (,,,, IBullaFactoringV2.FeeParams memory feeParams) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(feeParams.targetYieldBps, 0, "Target yield should be 0");
        // Total interest rate should still include protocol and admin fees
        assertGt(feeParams.protocolFeeBps + feeParams.adminFeeBps, 0, "Should still have protocol and admin fees");
    }
    
    function testOfferLoan_HighTargetYield() public {
        uint16 highYield = 5000; // 50%
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, highYield, 500, 100_000, 30 days, 365, "High yield test");
        vm.stopPrank();
        (,,,, IBullaFactoringV2.FeeParams memory feeParams) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(feeParams.targetYieldBps, highYield, "Target yield should match high value");
    }
    
    function testOfferLoan_ZeroSpread() public {
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 0, 100_000, 30 days, 365, "Zero spread test");
        vm.stopPrank();
        (,,,, IBullaFactoringV2.FeeParams memory feeParams) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(feeParams.spreadBps, 0, "Spread should be 0");
    }
    
    function testOfferLoan_MaximumSpread() public {
        uint16 maxSpread = 2000; // 20%
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, maxSpread, 100_000, 30 days, 365, "Max spread test");
        vm.stopPrank();
        (,,,, IBullaFactoringV2.FeeParams memory feeParams) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(feeParams.spreadBps, maxSpread, "Spread should match maximum value");
    }

    // ============= PARAMETER VALIDATION TESTS =============
    
    function testOfferLoan_ZeroPrincipalAmount() public {
        vm.startPrank(underwriter);
        // This should work as validation might be in BullaFrendLend
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 0, 30 days, 365, "Zero principal test");
        vm.stopPrank();
        (,, uint256 principalAmount,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(principalAmount, 0, "Principal amount should be 0");
    }
    
    function testOfferLoan_LargePrincipalAmount() public {
        uint256 largePrincipal = type(uint128).max; // Maximum for BullaFrendLend
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, largePrincipal, 30 days, 365, "Large principal test");
        vm.stopPrank();
        (,, uint256 principalAmount,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(principalAmount, largePrincipal, "Principal amount should match large value");
    }
    
    function testOfferLoan_ZeroTermLength() public {
        vm.startPrank(underwriter);
        vm.expectRevert(InvalidTermLength.selector);
        bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 0, 365, "Zero term test");
        vm.stopPrank();
    }
    
    function testOfferLoan_LongTermLength() public {
        uint256 longTerm = 365 days * 10; // 10 years
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 100_000, longTerm, 365, "Long term test");
        vm.stopPrank();
        (,,, uint256 termLength,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertEq(termLength, longTerm, "Term length should match long value");
    }

    // ============= STATE MANAGEMENT TESTS =============
    
    function testOfferLoan_PendingLoanOfferStorage() public {
        uint256 principalAmount = 123_456;
        uint16 targetYieldBps = 1234;
        uint16 _spreadBps = 567;
        uint256 termLength = 42 days;
        uint256 timestampBefore = block.timestamp;
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, targetYieldBps, _spreadBps, principalAmount, termLength, 365, "Storage test");
        vm.stopPrank();
        (
            bool exists,
            uint256 offeredAt,
            uint256 storedPrincipal,
            uint256 storedTermLength,
            IBullaFactoringV2.FeeParams memory feeParams
        ) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        // Verify all fields are stored correctly
        assertTrue(exists, "Exists should be true");
        assertGe(offeredAt, timestampBefore, "Offered timestamp should be current or later");
        assertEq(storedPrincipal, principalAmount, "Principal amount should match");
        assertEq(storedTermLength, termLength, "Term length should match");
        
        // Verify fee params
        assertEq(feeParams.targetYieldBps, targetYieldBps, "Target yield should match");
        assertEq(feeParams.spreadBps, _spreadBps, "Spread should match");
        assertEq(feeParams.upfrontBps, 100_00, "Upfront should be 100%");
        assertEq(feeParams.protocolFeeBps, protocolFeeBps, "Protocol fee should match contract setting");
        assertEq(feeParams.adminFeeBps, adminFeeBps, "Admin fee should match contract setting");
        assertEq(feeParams.minDaysInterestApplied, 0, "Min days should be 0");
    }
    
    function testOfferLoan_MultipleOffers() public {
        vm.startPrank(underwriter);
        
        // Create 3 different loan offers
        bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "Offer 1");
        bullaFactoring.offerLoan(alice, 1200, 600, 150_000, 45 days, 365, "Offer 2");
        bullaFactoring.offerLoan(charlie, 800, 400, 80_000, 20 days, 365, "Offer 3");
        
        vm.stopPrank();
        
        // Verify all offers are stored
        assertEq(getPendingLoanOffersCount(), 3, "Should have 3 pending offers");
        
        // Verify each offer has correct details
        for (uint i = 0; i < 3; i++) {
            uint256 loanOfferId = bullaFactoring.pendingLoanOffersIds(i);
            (bool exists,,,, ) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
            assertTrue(exists, "Each offer should exist");
        }
    }

    // ============= INTEGRATION TESTS =============
    
    function testOfferLoanAndAcceptance_ParameterPropagation() public {
        uint256 principalAmount = 200_000;
        uint256 termLength = 90 days;
        uint256 timestampBefore = block.timestamp;
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1500, 750, principalAmount, termLength, 365, "Propagation test");
        vm.stopPrank();
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = principalAmount * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Record balances before loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.prank(bob);
        bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            principalAmount,
            "Factoring contract should have transferred principal amount"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            principalAmount,
            "Bob should have received principal amount"
        );
        
        // Verify invoice approval contains correctly calculated values
        (
            bool approved,
            address creditor,
            uint256 validUntil,
            uint256 invoiceDueDate,
            uint256 fundedTimestamp,
            ,
            uint256 fundedAmountGross,
            uint256 fundedAmountNet,
            uint256 initialInvoiceValue,
            uint256 initialPaidAmount,
            address receiverAddress
        ) = bullaFactoring.approvedInvoices(loanOfferId);
        
        assertTrue(approved, "Should be approved");
        assertEq(creditor, address(bullaFactoring), "Creditor should be factoring contract");
        assertEq(fundedAmountGross, principalAmount, "Funded amount gross should equal principal");
        assertEq(fundedAmountNet, principalAmount, "Funded amount net should equal principal");
        assertEq(initialInvoiceValue, principalAmount, "Initial full amount should equal principal");
        assertEq(initialPaidAmount, 0, "Initial paid amount should be 0");
        assertEq(receiverAddress, address(bullaFactoring), "Receiver address should be factoring contract");
        assertGe(invoiceDueDate, timestampBefore + termLength, "Due date should be calculated correctly");
        assertGe(fundedTimestamp, timestampBefore, "Funded timestamp should be current time");
        assertLe(validUntil, timestampBefore + bullaFactoring.approvalDuration(), "Valid until should be based on approval duration");
    }
    
    function testOfferLoanAndAcceptance_TimestampHandling() public {
        uint256 offerTime = block.timestamp;
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "Timestamp test");
        vm.stopPrank();
        (bool exists, uint256 offeredAt,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        assertTrue(exists, "Offer should exist");
        assertGe(offeredAt, offerTime, "Offered timestamp should be set");
        
        // Wait some time before acceptance
        vm.warp(block.timestamp + 1 hours);
        uint256 acceptanceTime = block.timestamp;
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = 100_000 * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Record balances before loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        vm.prank(bob);
        bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after loan acceptance
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            100_000,
            "Factoring contract should have transferred principal amount"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            100_000,
            "Bob should have received principal amount"
        );
        
        // Verify timestamps in invoice approval
        (,, uint256 validUntil,, uint256 fundedTimestamp,,,,,, ) = bullaFactoring.approvedInvoices(loanOfferId);
        
        assertEq(validUntil, offeredAt, "Valid until should be the offered timestamp");
        assertGe(fundedTimestamp, acceptanceTime, "Funded timestamp should be acceptance time");
    }

    // ============= EDGE CASES =============
    
    function testOfferLoan_EmptyDescription() public {
        vm.startPrank(underwriter);
        bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "");
        vm.stopPrank();
        
        assertEq(getPendingLoanOffersCount(), 1, "Should create offer with empty description");
    }
    
    function testOfferLoan_LongDescription() public {
        string memory longDesc = "This is a very long description that contains many characters to test the behavior with lengthy strings and ensure that the contract can handle large text inputs without issues or gas problems";
        
        vm.startPrank(underwriter);
        bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, longDesc);
        vm.stopPrank();
        
        assertEq(getPendingLoanOffersCount(), 1, "Should create offer with long description");
    }
    
    function testOfferLoan_ZeroAddressDebtor() public {
        vm.startPrank(underwriter);
        // This might be validated by BullaFrendLend, but factoring contract should handle it
        bullaFactoring.offerLoan(address(0), 1000, 500, 100_000, 30 days, 365, "Zero address test");
        vm.stopPrank();
        
        assertEq(getPendingLoanOffersCount(), 1, "Should create offer with zero address debtor");
    }
    
    function testOfferLoan_SelfAsDebtor() public {
        vm.startPrank(underwriter);
        bullaFactoring.offerLoan(address(bullaFactoring), 1000, 500, 100_000, 30 days, 365, "Self debtor test");
        vm.stopPrank();
        
        assertEq(getPendingLoanOffersCount(), 1, "Should create offer with contract as debtor");
    }

    // ============= ARRAY MANAGEMENT TESTS =============
    
    function testOfferLoanAndAcceptance_ArrayManagement() public {

        vm.prank(alice);
        bullaFactoring.deposit(100000, alice);

        vm.startPrank(underwriter);
        
        // Create 5 loan offers
        for (uint i = 0; i < 5; i++) {
            bullaFactoring.offerLoan(
                bob,
                1000,
                500,
                100 + i * 1000,
                30 days,
                365, // numberOfPeriodsPerYear
                string(abi.encodePacked("Offer ", vm.toString(i)))
            );
        }
        
        vm.stopPrank();
        
        assertEq(getPendingLoanOffersCount(), 5, "Should have 5 pending offers");
        
        // Accept offers 1, 3, and 4 (not in order)
        uint256[] memory offerIds = new uint256[](5);
        for (uint i = 0; i < 5; i++) {
            offerIds[i] = bullaFactoring.pendingLoanOffersIds(i);
        }
        
        vm.startPrank(bob);
        bullaFrendLend.acceptLoan(offerIds[1]);
        bullaFrendLend.acceptLoan(offerIds[3]);
        bullaFrendLend.acceptLoan(offerIds[4]);
        vm.stopPrank();
        
        // Should have 2 pending offers left
        assertEq(getPendingLoanOffersCount(), 2, "Should have 2 pending offers remaining");
        
        // Should have 3 active invoices
        assertEq(getActiveInvoicesCount(), 3, "Should have 3 active invoices");
        
        // Verify remaining offers still exist
        (bool exists0,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(offerIds[0]);
        (bool exists2,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(offerIds[2]);
        
        assertTrue(exists0, "Offer 0 should still exist");
        assertTrue(exists2, "Offer 2 should still exist");
    }
    
    function testOfferLoanAndAcceptance_MappingConsistency() public {
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, 100_000, 30 days, 365, "Mapping test");
        vm.stopPrank();
        
        // Verify pending mapping exists
        (bool existsBefore,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertTrue(existsBefore, "Pending offer should exist");
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = 100_000 * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        vm.prank(bob);
        uint256 loanId = bullaFrendLend.acceptLoan(loanOfferId);
        
        // Verify pending mapping is cleaned up
        (bool existsAfter,,,,) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        assertFalse(existsAfter, "Pending offer should not exist after acceptance");
        
        // Verify invoice approval mapping is populated
        (bool approved,,,,,,,,,, ) = bullaFactoring.approvedInvoices(loanOfferId);
        assertTrue(approved, "Invoice approval should exist");
        
        // Verify original creditor mapping is set
        assertEq(
            bullaFactoring.originalCreditors(loanId),
            address(bullaFactoring),
            "Original creditor should be set"
        );
    }
    
    function testOfferLoanAndAcceptance_EventEmission() public {
        uint256 principalAmount = 250_000;
        uint256 termLength = 60 days;
        
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(bob, 1000, 500, principalAmount, termLength, 365, "Event test");
        vm.stopPrank();
        uint256 expectedDueDate = block.timestamp + termLength;
        
        // Alice makes a deposit to fund the pool
        uint256 depositAmount = principalAmount * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Record balances before loan acceptance
        uint256 factoringBalanceBefore = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        
        // Expect InvoiceFunded event
        vm.expectEmit(true, true, false, true);
        emit InvoiceFunded(
            bullaClaim.currentClaimId() + 1,
            principalAmount,
            address(bullaFactoring),
            expectedDueDate,
            100_00 // upfrontBps is always 100%
        );
        
        vm.prank(bob);
        bullaFrendLend.acceptLoan(loanOfferId);
        
        // Record balances after loan acceptance and verify fund transfers
        uint256 factoringBalanceAfter = asset.balanceOf(address(bullaFactoring));
        uint256 bobBalanceAfter = asset.balanceOf(bob);
        
        // Verify fund transfers
        assertEq(
            factoringBalanceBefore - factoringBalanceAfter,
            principalAmount,
            "Factoring contract should have transferred principal amount"
        );
        assertEq(
            bobBalanceAfter - bobBalanceBefore,
            principalAmount,
            "Bob should have received principal amount"
        );
    }

    // ============= INTEREST RATE VERIFICATION TESTS =============
    
    function testAcceptedLoanOffer_InterestRateEqualsSumOfAllFees() public {
        uint256 principalAmount = 150_000;
        uint16 targetYieldBps = 1200; // 12% APR
        uint16 _spreadBps = 800;       // 8% APR  
        uint256 termLength = 45 days;
        string memory description = "Interest rate verification test";
        
        // Calculate expected total interest rate
        uint16 expectedTotalInterestRateBps = targetYieldBps + _spreadBps + adminFeeBps + protocolFeeBps;
        
        // Create loan offer
        vm.startPrank(underwriter);
        uint256 loanOfferId = bullaFactoring.offerLoan(
            bob,
            targetYieldBps,
            _spreadBps,
            principalAmount,
            termLength,
            365, // numberOfPeriodsPerYear
            description
        );
        vm.stopPrank();
        
        // Alice deposits to fund the pool
        vm.startPrank(alice);
        bullaFactoring.deposit(principalAmount * 2, alice);
        vm.stopPrank();
        
        // Get pending loan offer fee params BEFORE acceptance (since they get removed after)
        (,,,, IBullaFactoringV2.FeeParams memory pendingFeeParams) = bullaFactoring.pendingLoanOffersByLoanOfferId(loanOfferId);
        
        // Accept loan offer
        vm.prank(bob);
        uint256 loanId = bullaFrendLend.acceptLoan(loanOfferId);
        
        // Verify the loan was created correctly by checking the due date calculation
        // The due date should be funding timestamp + term length
        (,,,uint256 invoiceDueDate,uint256 fundedTimestamp, IBullaFactoringV2.FeeParams memory feeParams,,,,,) = bullaFactoring.approvedInvoices(loanOfferId);
        
        assertEq(
            invoiceDueDate,
            fundedTimestamp + termLength,
            "Due date should be calculated from funding timestamp plus term length"
        );
        
        // Verify that the fee params were transferred correctly from pending to approved
        assertEq(feeParams.targetYieldBps, pendingFeeParams.targetYieldBps, "Target yield should transfer correctly");
        assertEq(feeParams.spreadBps, pendingFeeParams.spreadBps, "Spread should transfer correctly");
        assertEq(feeParams.protocolFeeBps, pendingFeeParams.protocolFeeBps, "Protocol fee should transfer correctly");
        assertEq(feeParams.adminFeeBps, pendingFeeParams.adminFeeBps, "Admin fee should transfer correctly");
        
        // Verify individual components match what was originally set
        assertEq(feeParams.targetYieldBps, targetYieldBps, "Target yield should match original");
        assertEq(feeParams.spreadBps, _spreadBps, "Spread should match original");
        assertEq(feeParams.protocolFeeBps, protocolFeeBps, "Protocol fee should match original");
        assertEq(feeParams.adminFeeBps, adminFeeBps, "Admin fee should match original");
        
        // Calculate the total interest rate that was passed to BullaFrendLend
        // This should be the sum of all fee components
        uint16 actualTotalFeeBps = feeParams.targetYieldBps + feeParams.spreadBps + feeParams.protocolFeeBps + feeParams.adminFeeBps;
        
        assertEq(
            actualTotalFeeBps,
            expectedTotalInterestRateBps,
            "Total interest rate should equal sum of all fee basis points"
        );

        Loan memory loan = bullaFrendLend.getLoan(loanId);

        assertEq(loan.interestConfig.interestRateBps, actualTotalFeeBps, "Interest rate should be equal to total fee basis points");
        assertEq(loan.interestComputationState.protocolFeeBps, 0, "Protocol fee should be exempt");

    }
    
    function testOfferLoan_365PeriodsYieldMoreInterestThan0Periods() public {
        uint256 principalAmount = 10_000;
        uint16 targetYieldBps = 1200; // 12% APR
        uint16 _spreadBps = 300; // 3% APR
        uint256 termLength = 365 days; // 1 year to allow for meaningful compounding test
        
        // Alice deposits funds to fund both loans
        vm.startPrank(alice);
        bullaFactoring.deposit(principalAmount * 4, alice);
        vm.stopPrank();
        
        // Create two identical loan offers with different numberOfPeriodsPerYear
        vm.startPrank(underwriter);
        
        uint256 loanOfferId365 = bullaFactoring.offerLoan(
            bob,
            targetYieldBps,
            _spreadBps,
            principalAmount,
            termLength,
            365, // 365 periods per year - daily compounding
            "365 periods test loan"
        );
        
        uint256 loanOfferId0 = bullaFactoring.offerLoan(
            bob,
            targetYieldBps,
            _spreadBps,
            principalAmount,
            termLength,
            0, // 0 periods per year - no compounding
            "0 periods test loan"
        );
        
        vm.stopPrank();
        
        // Accept both loans
        vm.startPrank(bob);
        uint256 loanId365 = bullaFrendLend.acceptLoan(loanOfferId365);
        uint256 loanId0 = bullaFrendLend.acceptLoan(loanOfferId0);
        vm.stopPrank();
        
        // Fast forward to a longer period to see meaningful compounding difference
        vm.warp(block.timestamp + 180 days); // 6 months
        
        // Get loan details from BullaFrendLend to check interest accrual
        Loan memory loan365 = bullaFrendLend.getLoan(loanId365);
        Loan memory loan0 = bullaFrendLend.getLoan(loanId0);
        
        // Verify both loans have the same basic parameters
        assertEq(loan365.claimAmount, loan0.claimAmount, "Both loans should have identical principal amounts");
        assertEq(loan365.interestConfig.interestRateBps, loan0.interestConfig.interestRateBps, "Both loans should have identical interest rates");
        
        // Verify different compounding frequencies
        assertEq(loan365.interestConfig.numberOfPeriodsPerYear, 365, "365-period loan should have 365 periods per year");
        assertEq(loan0.interestConfig.numberOfPeriodsPerYear, 0, "0-period loan should have 0 periods per year");
        
        // Get total amounts due for both loans
        (uint256 principal365, uint256 interest365) = bullaFrendLend.getTotalAmountDue(loanId365);
        (uint256 principal0, uint256 interest0) = bullaFrendLend.getTotalAmountDue(loanId0);
        
        uint256 totalDue365 = principal365 + interest365;
        uint256 totalDue0 = principal0 + interest0;
        
        // Verify both loans have the same principal
        assertEq(principal365, principal0, "Both loans should have identical principal amounts");
        assertEq(principal365, principalAmount, "Principal should match the original loan amount");
        
        // Verify that both loans accrued some interest
        assertGt(interest365, 0, "365-period loan should have accrued interest");
        assertGt(interest0, 0, "0-period loan should have accrued interest");
        
        // The key assertion: 365 periods should yield more interest than 0 periods
        // This is because 365 periods allows for compounding, while 0 periods is simple interest
        assertGt(interest365, interest0, "365 periods per year should yield more interest than 0 periods per year");
        assertGt(totalDue365, totalDue0, "365-period loan should have higher total amount due");
        
        // Verify the difference is meaningful (at least 0.1% more)
        uint256 minExpectedDifference = Math.mulDiv(interest0, 10, 10000); // 0.1% of the 0-period interest
        assertGe(interest365 - interest0, minExpectedDifference, "Interest difference should be meaningful");
        
        // Test that payments work correctly for both loan types
        vm.startPrank(bob);
        
        // Pay both loans in full
        asset.approve(address(bullaFrendLend), totalDue365);
        bullaFrendLend.payLoan(loanId365, totalDue365);
        
        asset.approve(address(bullaFrendLend), totalDue0);
        bullaFrendLend.payLoan(loanId0, totalDue0);
        
        vm.stopPrank();
        
        // Verify both loans are paid
        Loan memory paidLoan365 = bullaFrendLend.getLoan(loanId365);
        Loan memory paidLoan0 = bullaFrendLend.getLoan(loanId0);
        
        bullaFactoring.reconcileActivePaidInvoices();

        assertTrue(paidLoan365.status == Status.Paid, "365-period loan should be paid");
        assertTrue(paidLoan0.status == Status.Paid, "0-period loan should be paid");

        assertGt(bullaFactoring.paidInvoicesGain(loanId365), bullaFactoring.paidInvoicesGain(loanId0), "Paid invoices gain should be greater for 365-period loan");
    }
} 
