// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ClaimBinding, CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
import {EIP712Helper} from './utils/EIP712Helper.sol';
import {IBullaInvoice} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {IInvoiceProviderAdapterV2} from "contracts/interfaces/IInvoiceProviderAdapter.sol";

contract TestGetInvoiceDetailsGasCost is CommonSetup {
    EIP712Helper public sigHelper;
    
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
    
    function testViewPoolStatusVsReconcileWithPaidInvoices() public {
        console.log("\n=== Overhead WITH Paid Invoices (actual work) ===\n");

        uint256 numInvoices = 20;
        uint256 numPaid = 5; // Pay 5 out of 20
        
        // Setup: deposit funds and create/approve/fund invoices WITH late fees
        uint256 depositAmount = numInvoices * 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numInvoices);
        vm.startPrank(bob);
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceIds[i] = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly compounding
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, 0);
            vm.stopPrank();
            
            vm.startPrank(bob);
            IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceIds[i]); // Approve BullaInvoice NFT
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
        }
        vm.stopPrank();

        // Pay some invoices
        vm.startPrank(alice);
        uint256 totalPaymentAmount = numPaid * 100000; // Each invoice is 100,000
        asset.approve(address(bullaInvoice), totalPaymentAmount);
        for (uint256 i = 0; i < numPaid; i++) {
            bullaInvoice.payInvoice(invoiceIds[i], 100000);
        }
        vm.stopPrank();

        console.log("Total invoices:", numInvoices);
        console.log("Paid invoices:", numPaid);
        console.log("Unpaid invoices:", numInvoices - numPaid);
        console.log("");

        // Measure viewPoolStatus (just checking)
        uint256 gasBefore = gasleft();
        (uint256[] memory paidInvoices, , , ) = bullaFactoring.viewPoolStatus();
        uint256 gasAfter = gasleft();
        uint256 viewPoolStatusGas = gasBefore - gasAfter;

        console.log("Found", paidInvoices.length, "paid invoices");
        console.log("viewPoolStatus() gas:", viewPoolStatusGas);

        // Measure reconcilePaid (checking + processing payments)
        gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        gasAfter = gasleft();
        uint256 reconcileGas = gasBefore - gasAfter;

        console.log("reconcilePaid() gas:", reconcileGas);
        console.log("Processing overhead:", reconcileGas - viewPoolStatusGas);
        console.log("Gas per paid invoice processed:", (reconcileGas - viewPoolStatusGas) / paidInvoices.length);
    }

    function testDetailedGasBreakdown() public {
        console.log("\n=== DETAILED GAS BREAKDOWN ===\n");
        console.log("Testing with invoices that have late fee configuration\n");

        uint256 numInvoices = 20;
        uint256 numPaid = 5;
        
        // Setup with late fee invoices
        uint256 depositAmount = numInvoices * 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numInvoices);
            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                invoiceIds[i] = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR late fee
                vm.stopPrank();
                
                vm.startPrank(underwriter);
                bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, 0);
                vm.stopPrank();
                
                vm.startPrank(bob);
                IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceIds[i]); // Approve BullaInvoice NFT
                bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            }
            vm.stopPrank();

        // Pay some invoices
        vm.startPrank(alice);
        uint256 totalPaymentAmount = numPaid * 100000; // Each invoice is 100,000
        asset.approve(address(bullaInvoice), totalPaymentAmount);
        for (uint256 i = 0; i < numPaid; i++) {
            bullaInvoice.payInvoice(invoiceIds[i], 100000);
        }
        vm.stopPrank();

        // STEP 1: Measure viewPoolStatus alone
        uint256 gasBefore = gasleft();
        (uint256[] memory paidInvoiceIds, , , ) = bullaFactoring.viewPoolStatus();
        uint256 gasAfter = gasleft();
        uint256 viewPoolStatusGas = gasBefore - gasAfter;

        console.log("Step 1: viewPoolStatus()");
        console.log("  Gas cost:", viewPoolStatusGas);
        console.log("  Found", paidInvoiceIds.length, "paid invoices");
        console.log("");

        // STEP 2: Measure full reconcilePaid (includes both _reconcile and _processQueue)
        gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        gasAfter = gasleft();
        uint256 fullReconcileGas = gasBefore - gasAfter;

        console.log("Step 2: reconcilePaid() [full function]");
        console.log("  Gas cost:", fullReconcileGas);
        console.log("");

        // STEP 3: Calculate _reconcilePaid overhead
        // Since there's no redemption queue activity, we can estimate:
        uint256 reconcileOnlyOverhead = fullReconcileGas - viewPoolStatusGas;
        
        console.log("Step 3: Breakdown");
        console.log("  viewPoolStatus():              ", viewPoolStatusGas, "gas");
        console.log("  Total reconcile function:      ", fullReconcileGas, "gas");
        console.log("  _reconcile + _processQueue overhead:", reconcileOnlyOverhead, "gas");
        console.log("");

        // STEP 4: Test with redemption queue activity
        console.log("Step 4: Testing with redemption queue activity\n");
        
        // Create a scenario with redemption queue
        vm.startPrank(alice);
        uint256 shares = bullaFactoring.balanceOf(alice);
        bullaFactoring.redeem(shares / 2, alice, alice); // Try to redeem half (should queue)
        vm.stopPrank();

        // Now measure _processRedemptionQueue overhead
        gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        gasAfter = gasleft();
        uint256 reconcileWithQueueGas = gasBefore - gasAfter;

        console.log("  reconcile with queue processing:", reconcileWithQueueGas, "gas");
        
        // Handle potential underflow
        if (reconcileWithQueueGas > fullReconcileGas) {
            console.log("  Queue processing overhead:        ", reconcileWithQueueGas - fullReconcileGas, "gas");
        } else {
            console.log("  Queue processing saved:           ", fullReconcileGas - reconcileWithQueueGas, "gas (negative overhead)");
        }
    }


    function _measureThreeComponentGasBreakdown(uint256 numInvoices, uint256 numPaid) internal {
        // Setup: Create funded invoices using simple claims (not BullaInvoice)
        uint256 depositAmount = numInvoices > 0 ? numInvoices * 200000 : 1000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numInvoices);
        
        // Create and fund simple claims (not BullaInvoice to avoid approval issues)
        if (numInvoices > 0) {
            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                invoiceIds[i] = createClaim(bob, alice, 100000, dueBy);
                vm.stopPrank();
                
                vm.startPrank(underwriter);
                bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, 0);
                vm.stopPrank();
                
                vm.startPrank(bob);
                bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
                bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            }
            vm.stopPrank();

            // Pay some invoices to create realistic scenario
            if (numPaid > 0) {
                vm.startPrank(alice);
                uint256 totalPaymentAmount = numPaid * 100000; // Each invoice is 100,000
                asset.approve(address(bullaClaim), totalPaymentAmount);
                for (uint256 i = 0; i < numPaid; i++) {
                    bullaClaim.payClaim(invoiceIds[i], 100000);
                }
                vm.stopPrank();
            }
        }

        console.log("Setup complete:");
        console.log("  Total active invoices:", numInvoices);
        console.log("  Paid invoices:", numPaid);
        console.log("");

        // COMPONENT 3: Full reconcilePaid() (includes _reconcile + _processQueue)
        console.log("=== COMPONENT 3: reconcilePaid() ===");
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasAfter = gasleft();

        console.log("Gas used:", gasBefore - gasAfter);
        console.log("");
    }

    function testThreeComponentGasBreakdownWithOneInvoiceAndAllPaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 1 INVOICE ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(1, 1);
    }

    function testThreeComponentGasBreakdownWithOneInvoiceNonePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 1 INVOICE, 0 PAID ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(1, 0);
    }

    function testThreeComponentGasBreakdownWithFifteenInvoicesNonePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 15 INVOICES, 0 PAID ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(15, 0);
    }

    function testThreeComponentGasBreakdownWithThirtyInvoicesNonePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 30 INVOICES, 0 PAID ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(30, 0);
    }

    function testThreeComponentGasBreakdownWithSixtyInvoicesNonePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 60 INVOICES, 0 PAID ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(60, 0);
    }

    function testThreeComponentGasBreakdownWithNinetyInvoicesNonePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 90 INVOICES, 0 PAID ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(90, 0);
    }

    // ========================================
    // INDIVIDUAL FUNCTION GAS TESTS  
    // ========================================

    function _setupInvoicesOnly(uint256 numInvoices) internal {
        uint256 depositAmount = numInvoices > 0 ? numInvoices * 200000 : 1000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        if (numInvoices > 0) {
            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                uint256 invoiceId = createClaim(bob, alice, 100000, dueBy);
                vm.stopPrank();
                
                vm.startPrank(underwriter);
                bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
                vm.stopPrank();
                
                vm.startPrank(bob);
                bullaClaim.approve(address(bullaFactoring), invoiceId);
                bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            }
            vm.stopPrank();
        }
    }

    // calculateCapitalAccount() tests - ISOLATED GAS MEASUREMENT
    function testCalculateCapitalAccountZeroInvoices() public {
        _setupInvoicesOnly(0);
        uint256 gasBefore = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("calculateCapitalAccount() with 0 invoices used:", gasUsed, "gas");
    }

    function testCalculateCapitalAccountOneInvoice() public {
        _setupInvoicesOnly(1);
        uint256 gasBefore = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("calculateCapitalAccount() with 1 invoice used:", gasUsed, "gas");
    }

    function testCalculateCapitalAccountFifteenInvoices() public {
        _setupInvoicesOnly(15);
        uint256 gasBefore = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("calculateCapitalAccount() with 15 invoices used:", gasUsed, "gas");
    }

    function testCalculateCapitalAccountThirtyInvoices() public {
        _setupInvoicesOnly(30);
        uint256 gasBefore = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("calculateCapitalAccount() with 30 invoices used:", gasUsed, "gas");
    }

    function testCalculateCapitalAccountSixtyInvoices() public {
        _setupInvoicesOnly(60);
        uint256 gasBefore = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("calculateCapitalAccount() with 60 invoices used:", gasUsed, "gas");
    }

    function testCalculateCapitalAccountNinetyInvoices() public {
        _setupInvoicesOnly(90);
        uint256 gasBefore = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("calculateCapitalAccount() with 90 invoices used:", gasUsed, "gas");
    }

    // totalAssets() tests
    function testTotalAssetsZeroInvoices() public {
        _setupInvoicesOnly(0);
        bullaFactoring.totalAssets();
    }

    function testTotalAssetsOneInvoice() public {
        _setupInvoicesOnly(1);
        bullaFactoring.totalAssets();
    }

    function testTotalAssetsFifteenInvoices() public {
        _setupInvoicesOnly(15);
        bullaFactoring.totalAssets();
    }

    function testTotalAssetsThirtyInvoices() public {
        _setupInvoicesOnly(30);
        bullaFactoring.totalAssets();
    }

    function testTotalAssetsSixtyInvoices() public {
        _setupInvoicesOnly(60);
        bullaFactoring.totalAssets();
    }

    function testTotalAssetsNinetyInvoices() public {
        _setupInvoicesOnly(90);
        bullaFactoring.totalAssets();
    }

    function testTotalAssets125Invoices() public {
        _setupInvoicesOnly(125);
        console.log("Testing totalAssets() with 125 invoices");
        uint256 gasBefore = gasleft();
        bullaFactoring.totalAssets();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("totalAssets() with 125 invoices used:", gasUsed, "gas");
    }

    function testTotalAssets250Invoices() public {
        _setupInvoicesOnly(250);
        console.log("Testing totalAssets() with 250 invoices");
        uint256 gasBefore = gasleft();
        bullaFactoring.totalAssets();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("totalAssets() with 250 invoices used:", gasUsed, "gas");
    }

    // maxRedeem() tests
    function testMaxRedeemZeroInvoices() public {
        _setupInvoicesOnly(0);
        bullaFactoring.maxRedeem(alice);
    }

    function testMaxRedeemOneInvoice() public {
        _setupInvoicesOnly(1);
        bullaFactoring.maxRedeem(alice);
    }

    function testMaxRedeemFifteenInvoices() public {
        _setupInvoicesOnly(15);
        bullaFactoring.maxRedeem(alice);
    }

    function testMaxRedeemThirtyInvoices() public {
        _setupInvoicesOnly(30);
        bullaFactoring.maxRedeem(alice);
    }

    function testMaxRedeemSixtyInvoices() public {
        _setupInvoicesOnly(60);
        bullaFactoring.maxRedeem(alice);
    }

    function testMaxRedeemNinetyInvoices() public {
        _setupInvoicesOnly(90);
        bullaFactoring.maxRedeem(alice);
    }

    // ========================================
    // GAS LIMIT ANALYSIS TESTS
    // ========================================

    function _setupAndPayInvoices(uint256 numInvoices, uint256 numToPay) internal returns (uint256[] memory invoiceIds) {
        // Setup invoices
        uint256 depositAmount = numInvoices > 0 ? numInvoices * 200000 : 1000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        invoiceIds = new uint256[](numInvoices);
        
        if (numInvoices > 0) {
            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                uint256 invoiceId = createClaim(bob, alice, 100000, dueBy);
                invoiceIds[i] = invoiceId;
                vm.stopPrank();
                
                vm.startPrank(underwriter);
                bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
                vm.stopPrank();
                
                vm.startPrank(bob);
                bullaClaim.approve(address(bullaFactoring), invoiceId);
                bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            }
            vm.stopPrank();

            // Pay the specified number of invoices
            if (numToPay > 0) {
                uint256 totalPaymentAmount = numToPay * 100000;
                vm.startPrank(alice);
                asset.approve(address(bullaClaim), totalPaymentAmount);
                for (uint256 i = 0; i < numToPay; i++) {
                    bullaClaim.payClaim(invoiceIds[i], 100000);
                }
                vm.stopPrank();
            }
        }
    }

    function testReconcileGasLimit10Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(10, 10);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 10 paid invoices gas used:", gasUsed);
    }

    function testReconcileGasLimit25Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(25, 25);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 25 paid invoices gas used:", gasUsed);
    }

    function testReconcileGasLimit50Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(50, 50);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 50 paid invoices gas used:", gasUsed);
    }

    function testReconcileGasLimit75Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(75, 75);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 75 paid invoices gas used:", gasUsed);
    }

    function testReconcileGasLimit100Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(100, 100);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 100 paid invoices gas used:", gasUsed);
    }

    function testReconcileGasLimit150Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(150, 150);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 150 paid invoices gas used:", gasUsed);
    }

    function testReconcileGasLimit200Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayInvoices(200, 200);
        
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Reconcile 200 paid invoices gas used:", gasUsed);
    }

    // ========================================
    // INVOICE TYPE GAS COMPARISON TESTS
    // ========================================

    function testGetInvoiceDetailsGasCostComparison() public {
        console.log("\n=== INVOICE TYPES GAS COST COMPARISON ===");
        console.log("Comparing getInvoiceDetails gas costs after 60 days\n");

        // Setup: Create three different types of invoices
        uint256 claimId = _createBullaClaimV2();
        uint256 invoiceNoLateFeeId = _createBullaInvoiceWithoutLateFee();
        uint256 invoiceWithLateFeeId = _createBullaInvoiceWithLateFee();

        // Warp 60 days for all invoices to normalize timing
        vm.warp(block.timestamp + 60 days);

        IInvoiceProviderAdapterV2 invoiceProviderAdapter = bullaFactoring.invoiceProviderAdapter();

        // Test 1: BullaClaimV2 gas cost
        uint256 gasBefore1 = gasleft();
        invoiceProviderAdapter.getInvoiceDetails(claimId);
        uint256 gasUsed1 = gasBefore1 - gasleft();
        console.log("BullaClaimV2 getClaim():                 ", gasUsed1, "gas");

        // Test 2: BullaInvoice (no late fee) gas cost via adapter
        uint256 gasBefore2 = gasleft();
        invoiceProviderAdapter.getInvoiceDetails(invoiceNoLateFeeId);
        uint256 gasUsed2 = gasBefore2 - gasleft();
        console.log("BullaInvoice (no late fee) via adapter:        ", gasUsed2, "gas");

        // Test 3: BullaInvoice (with late fee) gas cost via adapter
        uint256 gasBefore3 = gasleft();
        invoiceProviderAdapter.getInvoiceDetails(invoiceWithLateFeeId);
        uint256 gasUsed3 = gasBefore3 - gasleft();
        console.log("BullaInvoice (with late fee) via adapter:       ", gasUsed3, "gas");

        // Calculate differences
        console.log("\n=== COMPARISON ANALYSIS ===");
        if (gasUsed2 > gasUsed1) {
            uint256 overhead = gasUsed2 - gasUsed1;
            uint256 pct = (overhead * 100) / gasUsed1;
            console.log("BullaInvoice (no late fee) overhead:   +", overhead, "gas");
            console.log("  Percentage increase:                  +", pct, "%");
        } else {
            uint256 savings = gasUsed1 - gasUsed2;
            uint256 pct = (savings * 100) / gasUsed1;
            console.log("BullaInvoice (no late fee) savings:    -", savings, "gas");
            console.log("  Percentage decrease:                  -", pct, "%");
        }

        if (gasUsed3 > gasUsed1) {
            uint256 overhead = gasUsed3 - gasUsed1;
            uint256 pct = (overhead * 100) / gasUsed1;
            console.log("BullaInvoice (with late fee) overhead: +", overhead, "gas");
            console.log("  Percentage increase:                  +", pct, "%");
        } else {
            uint256 savings = gasUsed1 - gasUsed3;
            uint256 pct = (savings * 100) / gasUsed1;
            console.log("BullaInvoice (with late fee) savings:  -", savings, "gas");
            console.log("  Percentage decrease:                  -", pct, "%");
        }

        if (gasUsed3 > gasUsed2) {
            uint256 overhead = gasUsed3 - gasUsed2;
            uint256 pct = (overhead * 100) / gasUsed2;
            console.log("Late fee calculation overhead:         +", overhead, "gas");
            console.log("  Late fee percentage increase:        +", pct, "%");
        } else {
            console.log("Late fee calculation cost:             Same as no late fee");
        }
    }

    function _createBullaClaimV2() internal returns (uint256 claimId) {
        vm.startPrank(bob);
        claimId = createClaim(bob, alice, 100000, dueBy);
        vm.stopPrank();
        
        console.log("Created BullaClaimV2 ID:", claimId);

        bullaFactoring.invoiceProviderAdapter().initializeInvoice(claimId);
        return claimId;
    }

    function _createBullaInvoiceWithoutLateFee() internal returns (uint256 invoiceId) {
        vm.startPrank(bob);

        // Create BullaInvoice without late fee (lateFee = 0, gracePeriodDays = 0)
        invoiceId = createInvoice(bob, alice, 100000, dueBy, 0, 0);
        vm.stopPrank();

        bullaFactoring.invoiceProviderAdapter().initializeInvoice(invoiceId);
        
        console.log("Created BullaInvoice (no late fee) ID:", invoiceId);
        return invoiceId;
    }

    function _createBullaInvoiceWithLateFee() internal returns (uint256 invoiceId) {
        vm.startPrank(bob);

        // Create BullaInvoice with late fee (lateFee = 1000 bps = 10%, gracePeriodDays = 12)
        invoiceId = createInvoice(bob, alice, 100000, dueBy, 1000, 12);
        vm.stopPrank();

        bullaFactoring.invoiceProviderAdapter().initializeInvoice(invoiceId);
        
        console.log("Created BullaInvoice (with late fee) ID:", invoiceId);
        return invoiceId;
    }

    function testInvoiceTypeGasScaling() public {
        console.log("\n=== INVOICE TYPE GAS SCALING TEST ===");
        console.log("Testing gas costs with multiple calls\n");

        uint256 claimId = _createBullaClaimV2();
        uint256 invoiceNoLateFeeId = _createBullaInvoiceWithoutLateFee();  
        uint256 invoiceWithLateFeeId = _createBullaInvoiceWithLateFee();

        // Warp 60 days
        vm.warp(block.timestamp + 60 days);

        uint256 iterations = 10;
        
        // Test BullaClaimV2 multiple calls
        uint256 totalGas1 = 0;
        for (uint256 i = 0; i < iterations; i++) {
            uint256 gasBefore = gasleft();
            bullaClaim.getClaim(claimId);
            totalGas1 += gasBefore - gasleft();
        }
        uint256 avgGas1 = totalGas1 / iterations;

        // Test BullaInvoice (no late fee) multiple calls
        uint256 totalGas2 = 0;
        for (uint256 i = 0; i < iterations; i++) {
            uint256 gasBefore = gasleft();
            bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(invoiceNoLateFeeId);
            totalGas2 += gasBefore - gasleft();
        }
        uint256 avgGas2 = totalGas2 / iterations;

        // Test BullaInvoice (with late fee) multiple calls
        uint256 totalGas3 = 0;
        for (uint256 i = 0; i < iterations; i++) {
            uint256 gasBefore = gasleft();
            bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(invoiceWithLateFeeId);
            totalGas3 += gasBefore - gasleft();
        }
        uint256 avgGas3 = totalGas3 / iterations;

        console.log("Average gas over", iterations, "calls:");
        console.log("BullaClaimV2:                          ", avgGas1, "gas");
        console.log("BullaInvoice (no late fee):           ", avgGas2, "gas");
        console.log("BullaInvoice (with late fee):         ", avgGas3, "gas");

        console.log("\nConsistency check:");
        console.log("BullaClaimV2 total variation:          ", totalGas1 - (avgGas1 * iterations), "gas");
        console.log("BullaInvoice (no late fee) variation:  ", totalGas2 - (avgGas2 * iterations), "gas");
        console.log("BullaInvoice (with late fee) variation:", totalGas3 - (avgGas3 * iterations), "gas");
    }

    function testDirectBullaInvoiceGasComparison() public {
        console.log("\n=== DIRECT BULLA INVOICE GAS COMPARISON ===");
        console.log("Isolating the bullaInvoice.getInvoice() call itself\n");

        uint256 invoiceNoLateFeeId = _createBullaInvoiceWithoutLateFee();
        uint256 invoiceWithLateFeeId = _createBullaInvoiceWithLateFee();

        // Warp 60 days
        vm.warp(block.timestamp + 60 days);

        // Get reference to the BullaInvoice contract through the adapter
        IBullaInvoice bullaInvoiceContract = IBullaInvoice(address(bullaInvoice));

        // Test 1: Direct call to BullaInvoice (no late fee)
        uint256 gasBefore1 = gasleft();
        bullaInvoiceContract.getInvoice(invoiceNoLateFeeId);
        uint256 gasUsed1 = gasBefore1 - gasleft();
        console.log("BullaInvoice.getInvoice() (no late fee):      ", gasUsed1, "gas");

        // Test 2: Direct call to BullaInvoice (with late fee)
        uint256 gasBefore2 = gasleft();
        bullaInvoiceContract.getInvoice(invoiceWithLateFeeId);
        uint256 gasUsed2 = gasBefore2 - gasleft();
        console.log("BullaInvoice.getInvoice() (with late fee):    ", gasUsed2, "gas");

        // Test 3: Adapter wrapper cost for no late fee
        uint256 gasBefore3 = gasleft();
        bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(invoiceNoLateFeeId);
        uint256 gasUsed3 = gasBefore3 - gasleft();
        uint256 adapterOverhead1 = gasUsed3 - gasUsed1;
        console.log("Adapter overhead (no late fee):              ", adapterOverhead1, "gas");

        // Test 4: Adapter wrapper cost for with late fee
        uint256 gasBefore4 = gasleft();
        bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(invoiceWithLateFeeId);
        uint256 gasUsed4 = gasBefore4 - gasleft();
        uint256 adapterOverhead2 = gasUsed4 - gasUsed2;
        console.log("Adapter overhead (with late fee):            ", adapterOverhead2, "gas");

        console.log("\n=== DETAILED ANALYSIS ===");
        if (gasUsed2 > gasUsed1) {
            console.log("Late fee adds:", gasUsed2 - gasUsed1, "gas to direct call");
        } else if (gasUsed1 > gasUsed2) {
            console.log("No late fee adds:", gasUsed1 - gasUsed2, "gas to direct call");
        } else {
            console.log("Direct calls use same gas");
        }

        if (adapterOverhead2 > adapterOverhead1) {
            console.log("Late fee adds:", adapterOverhead2 - adapterOverhead1, "gas to adapter overhead");
        } else if (adapterOverhead1 > adapterOverhead2) {
            console.log("No late fee adds:", adapterOverhead1 - adapterOverhead2, "gas to adapter overhead");
        } else {
            console.log("Adapter overhead is same");
        }
    }

    function testAdapterOptimizationImpact() public {
        console.log("\n=== ADAPTER OPTIMIZATION IMPACT TEST ===");
        console.log("Testing gas savings from caching interestComputationState fields\n");

        uint256 invoiceNoLateFeeId = _createBullaInvoiceWithoutLateFee();
        uint256 invoiceWithLateFeeId = _createBullaInvoiceWithLateFee();

        // Warp 60 days
        vm.warp(block.timestamp + 60 days);

        // Test multiple calls to see consistent savings
        uint256 iterations = 10;
        uint256 totalGasNoLateFee = 0;
        uint256 totalGasWithLateFee = 0;

        // Measure no late fee
        for (uint256 i = 0; i < iterations; i++) {
            uint256 gasBefore = gasleft();
            bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(invoiceNoLateFeeId);
            totalGasNoLateFee += gasBefore - gasleft();
        }

        // Measure with late fee
        for (uint256 i = 0; i < iterations; i++) {
            uint256 gasBefore = gasleft();
            bullaFactoring.invoiceProviderAdapter().getInvoiceDetails(invoiceWithLateFeeId);
            totalGasWithLateFee += gasBefore - gasleft();
        }

        uint256 avgGasNoLateFee = totalGasNoLateFee / iterations;
        uint256 avgGasWithLateFee = totalGasWithLateFee / iterations;

        console.log("Average gas (no late fee):    ", avgGasNoLateFee);
        console.log("Average gas (with late fee):  ", avgGasWithLateFee);

        if (avgGasWithLateFee < avgGasNoLateFee) {
            uint256 savings = avgGasNoLateFee - avgGasWithLateFee;
            uint256 savingsPct = (savings * 100) / avgGasNoLateFee;
            console.log("Gas savings from optimization:", savings, "gas");
            console.log("Percentage savings:           ", savingsPct, "%");
        } else if (avgGasNoLateFee < avgGasWithLateFee) {
            uint256 overhead = avgGasWithLateFee - avgGasNoLateFee;
            uint256 overheadPct = (overhead * 100) / avgGasNoLateFee;
            console.log("Late fee overhead:           ", overhead, "gas");
            console.log("Percentage overhead:         ", overheadPct, "%");
        } else {
            console.log("Gas usage is identical");
        }
    }

    function testControllerCachingOptimization() public {
        console.log("\n=== CONTROLLER CACHING OPTIMIZATION TEST ===");
        console.log("Testing gas savings from caching controller addresses\n");

        uint256 invoiceNoLateFeeId = _createBullaInvoiceWithoutLateFee();
        uint256 invoiceWithLateFeeId = _createBullaInvoiceWithLateFee();

        // Warp 60 days
        vm.warp(block.timestamp + 60 days);

        IInvoiceProviderAdapterV2 adapter = bullaFactoring.invoiceProviderAdapter();

        console.log("=== FIRST CALLS (Cache Miss) ===");
        
        // First call - should populate cache
        uint256 gasBefore1 = gasleft();
        adapter.getInvoiceDetails(invoiceNoLateFeeId);
        uint256 firstCallGas1 = gasBefore1 - gasleft();
        console.log("No late fee - First call:      ", firstCallGas1, "gas");

        uint256 gasBefore2 = gasleft();
        adapter.getInvoiceDetails(invoiceWithLateFeeId);
        uint256 firstCallGas2 = gasBefore2 - gasleft();
        console.log("With late fee - First call:    ", firstCallGas2, "gas");

        console.log("\n=== SECOND CALLS (Cache Hit Expected) ===");
        
        // Second call - should use cache (if implemented)
        uint256 gasBefore3 = gasleft();
        adapter.getInvoiceDetails(invoiceNoLateFeeId);
        uint256 secondCallGas1 = gasBefore3 - gasleft();
        console.log("No late fee - Second call:     ", secondCallGas1, "gas");

        uint256 gasBefore4 = gasleft();
        adapter.getInvoiceDetails(invoiceWithLateFeeId);
        uint256 secondCallGas2 = gasBefore4 - gasleft();
        console.log("With late fee - Second call:   ", secondCallGas2, "gas");

        console.log("\n=== CACHING ANALYSIS ===");
        
        if (secondCallGas1 < firstCallGas1) {
            uint256 savings1 = firstCallGas1 - secondCallGas1;
            console.log("No late fee savings:           ", savings1, "gas");
        } else {
            console.log("No late fee: No caching benefit detected");
        }

        if (secondCallGas2 < firstCallGas2) {
            uint256 savings2 = firstCallGas2 - secondCallGas2;
            console.log("With late fee savings:         ", savings2, "gas");
        } else {
            console.log("With late fee: No caching benefit detected");
        }
    }

    function testAdapterOverheadBreakdown() public {
        console.log("\n=== ADAPTER OVERHEAD BREAKDOWN ===");
        console.log("Isolating each step in the adapter execution\n");

        uint256 invoiceNoLateFeeId = _createBullaInvoiceWithoutLateFee();
        uint256 invoiceWithLateFeeId = _createBullaInvoiceWithLateFee();

        // Warp 60 days
        vm.warp(block.timestamp + 60 days);

        IInvoiceProviderAdapterV2 adapter = bullaFactoring.invoiceProviderAdapter();

        console.log("=== NO LATE FEE INVOICE BREAKDOWN ===");
        _measureAdapterSteps(invoiceNoLateFeeId, adapter);

        console.log("\n=== WITH LATE FEE INVOICE BREAKDOWN ===");
        _measureAdapterSteps(invoiceWithLateFeeId, adapter);
    }

    function _measureAdapterSteps(uint256 invoiceId, IInvoiceProviderAdapterV2 adapter) internal {
        // Step 1: Full adapter call (total)
        uint256 gasBefore3 = gasleft();
        adapter.getInvoiceDetails(invoiceId);
        uint256 fullAdapterGas = gasBefore3 - gasleft();
        console.log("1. Full adapter.getInvoiceDetails():    ", fullAdapterGas, "gas");

        // Step 2: Direct BullaInvoice call (baseline)
        IBullaInvoice bullaInvoiceContract = IBullaInvoice(address(bullaInvoice));
        uint256 gasBefore1 = gasleft();
        bullaInvoiceContract.getInvoice(invoiceId);
        uint256 directCallGas = gasBefore1 - gasleft();
        console.log("2. Direct bullaInvoice.getInvoice():     ", directCallGas, "gas");

        // Step 3: Initial getClaim call (what adapter does first)
        uint256 gasBefore2 = gasleft();
        bullaClaim.getClaim(invoiceId);
        uint256 getClaimGas = gasBefore2 - gasleft();
        console.log("3. Initial bullaClaim.getClaim():       ", getClaimGas, "gas");

        // Calculate overheads
        uint256 adapterOverhead = fullAdapterGas - directCallGas;
        uint256 getClaimOverhead = getClaimGas;
        
        uint256 processingOverhead = 0;
        if (fullAdapterGas > directCallGas + getClaimGas) {
            processingOverhead = fullAdapterGas - directCallGas - getClaimGas;
        } else if (fullAdapterGas > directCallGas) {
            processingOverhead = fullAdapterGas - directCallGas;
            console.log("Note: getClaim measurement higher than actual adapter usage");
        }

        console.log("\n--- OVERHEAD ANALYSIS ---");
        console.log("Total adapter overhead:                 ", adapterOverhead, "gas");
        console.log("  getClaim() overhead:                  ", getClaimOverhead, "gas");
        console.log("  Processing/struct overhead:           ", processingOverhead, "gas");

        // Calculate percentages
        if (adapterOverhead > 0) {
            uint256 getClaimPct = (getClaimOverhead * 100) / adapterOverhead;
            console.log("  getClaim() as % of overhead:          ", getClaimPct, "%");
            
            if (processingOverhead > 0) {
                uint256 processingPct = (processingOverhead * 100) / adapterOverhead;
                console.log("  Processing as % of overhead:          ", processingPct, "%");
            } else {
                console.log("  Processing overhead: Negligible or optimized away");
            }
        }

        // Additional breakdown - what's in processing overhead?
        console.log("\n--- PROCESSING OVERHEAD DETAILS ---");
        uint256 secondCallExpected = directCallGas; // Second bullaInvoice.getInvoice() call
        
        console.log("  Expected 2nd bullaInvoice call:       ", secondCallExpected, "gas");
        console.log("  Actual processing overhead:           ", processingOverhead, "gas");
        
        if (processingOverhead >= secondCallExpected) {
            uint256 arithmeticAndStructGas = processingOverhead - secondCallExpected;
            console.log("  Arithmetic + struct construction:     ", arithmeticAndStructGas, "gas");
            uint256 arithmeticPct = (arithmeticAndStructGas * 100) / processingOverhead;
            console.log("  Arithmetic as % of processing:        ", arithmeticPct, "%");
        } else {
            uint256 savings = secondCallExpected - processingOverhead;
            console.log("  Processing overhead less than expected by: ", savings, "gas");
            console.log("  (This suggests call overlap or optimization)");
        }
    }

    function _setupAndPayCachedInvoices(uint256 numInvoices, uint256 numToPay) internal returns (uint256[] memory invoiceIds) {
        uint16 interestApr = 1000;
        uint16 spreadBps = 100;
        uint16 upfrontBps = 500;
        uint16 minDays = 30;
        uint256 dueBy = block.timestamp + 365 days;

        // Setup liquidity
        uint256 depositAmount = numInvoices > 0 ? numInvoices * 200000 : 1000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        invoiceIds = new uint256[](numInvoices);
        
        if (numInvoices > 0) {
            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                // Create BullaInvoice (with late fee for consistency)
                uint256 invoiceId = createInvoice(bob, alice, 100000, dueBy, 1000, 12);
                invoiceIds[i] = invoiceId;
                vm.stopPrank();
                
                vm.startPrank(underwriter);
                bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
                vm.stopPrank();
                
                vm.startPrank(bob);
                IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId);
                bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            }
            vm.stopPrank();

            // Pay the specified number of invoices
            if (numToPay > 0) {
                uint256 totalPaymentAmount = numToPay * 100000;
                vm.startPrank(alice);
                asset.approve(address(bullaInvoice), totalPaymentAmount);
                for (uint256 i = 0; i < numToPay; i++) {
                    bullaInvoice.payInvoice(invoiceIds[i], 100000);
                }
                vm.stopPrank();
            }
        }

        return invoiceIds;
    }

    function testOptimizedReconcileGasLimit10Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(10, 10);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 10 paid invoices gas used:", gasUsed);
    }

    function testOptimizedReconcileGasLimit25Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(25, 25);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 25 paid invoices gas used:", gasUsed);
    }

    function testOptimizedReconcileGasLimit50Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(50, 50);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 50 paid invoices gas used:", gasUsed);
    }

    function testOptimizedReconcileGasLimit75Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(75, 75);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 75 paid invoices gas used:", gasUsed);
    }

    function testOptimizedReconcileGasLimit100Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(100, 100);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 100 paid invoices gas used:", gasUsed);
    }

    function testOptimizedReconcileGasLimit150Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(150, 150);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 150 paid invoices gas used:", gasUsed);
    }

    function testOptimizedReconcileGasLimit200Invoices() public {
        uint256[] memory invoiceIds = _setupAndPayCachedInvoices(200, 200);
        uint256 gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        uint256 gasUsed = gasBefore - gasleft();
        console.log("Optimized reconcile 200 paid invoices gas used:", gasUsed);
    }


    function testThreeComponentGasBreakdownWithFifteenInvoicesAndAllPaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 15 INVOICES ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(15, 15);
    }

    function testThreeComponentGasBreakdownWith90InvoicesAndAllPaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - 90 INVOICES ===");
        console.log("Measuring: reconcilePaid only\n");
        _measureThreeComponentGasBreakdown(90, 90);
    }

    function testThreeComponentGasBreakdownWith60InvoicesAndAllPaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN ===");
        console.log("Measuring: viewPoolStatus, _reconcilePaid, _processRedemptionQueue\n");
        _measureThreeComponentGasBreakdown(60, 60);
    }

    function testThreeComponentGasBreakdownWithThirtyInvoicesAndFivePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN ===");
        console.log("Measuring: viewPoolStatus, _reconcilePaid, _processRedemptionQueue\n");
        _measureThreeComponentGasBreakdown(30, 30);
    }

    function testThreeComponentGasBreakdownWith15InvoicesAndFivePaid() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN ===");
        console.log("Measuring: viewPoolStatus, _reconcilePaid, _processRedemptionQueue\n");
        _measureThreeComponentGasBreakdown(15, 15);
    }

    function testThreeComponentGasBreakdownWithZeroInvoices() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - ZERO ACTIVE INVOICES ===");
        console.log("Measuring baseline costs when no invoices are active\n");
        _measureThreeComponentGasBreakdown(0, 0);
    }
}

