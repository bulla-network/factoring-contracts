// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract TestGetInvoiceDetailsGasCost is CommonSetup {
    
    function testMeasureGetInvoiceDetailsGasCost() public {
        // Create a single invoice WITH late fee configuration
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly
        vm.stopPrank();

        // Measure gas for getInvoiceDetails
        uint256 gasBefore = gasleft();
        invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        uint256 gasAfter = gasleft();
        
        uint256 gasUsed = gasBefore - gasAfter;
        
        console.log("=== getInvoiceDetails Gas Cost ===");
        console.log("Gas used for getInvoiceDetails():", gasUsed);
        
        // Also measure the underlying getClaim call
        vm.startPrank(bob);
        gasBefore = gasleft();
        bullaClaim.getClaim(invoiceId);
        gasAfter = gasleft();
        vm.stopPrank();
        
        uint256 getClaimGas = gasBefore - gasAfter;
        console.log("Gas used for getClaim():", getClaimGas);
        console.log("Adapter overhead:", gasUsed - getClaimGas);
    }

    function testCompareStaticVsNonStaticCall() public {
        // Create a single invoice WITH late fee configuration
        vm.startPrank(bob);
        uint256 invoiceId = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly
        vm.stopPrank();

        console.log("\n=== Static vs Non-Static Call Comparison ===");
        
        // This is how it's called in viewPoolStatus (via isInvoicePaid)
        // It's a view function, so it should use staticcall
        uint256 gasBefore = gasleft();
        invoiceAdapterBulla.getInvoiceDetails(invoiceId);
        uint256 gasAfter = gasleft();
        
        console.log("View call gas (staticcall):", gasBefore - gasAfter);
    }

    function testGetInvoiceDetailsInLoop() public {
        uint256 numInvoices = 10;
        uint256[] memory invoiceIds = new uint256[](numInvoices);
        
        // Create multiple invoices WITH late fee configuration
        vm.startPrank(bob);
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceIds[i] = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly
        }
        vm.stopPrank();

        console.log("\n=== Gas Cost in Loop ===");
        
        // Measure gas for calling getInvoiceDetails in a loop
        uint256 gasBefore = gasleft();
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceAdapterBulla.getInvoiceDetails(invoiceIds[i]);
        }
        uint256 gasAfter = gasleft();
        
        uint256 totalGas = gasBefore - gasAfter;
        uint256 averageGasPerCall = totalGas / numInvoices;
        
        console.log("Total gas for", numInvoices, "calls:", totalGas);
        console.log("Average gas per call:", averageGasPerCall);
        console.log("First call overhead:", totalGas - (averageGasPerCall * numInvoices));
    }

    function testGetInvoiceDetailsCostBreakdown() public {
        // Create invoices with different states WITH late fee configuration
        vm.startPrank(bob);
        uint256 unpaidInvoice = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly
        uint256 partiallyPaidInvoice = createInvoice(bob, alice, 100000, dueBy, 1000, 12);
        vm.stopPrank();

        // Make a partial payment
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 50000);
        bullaClaim.payClaim(partiallyPaidInvoice, 50000);
        vm.stopPrank();

        console.log("\n=== Gas Cost by Invoice State ===");
        
        // Unpaid invoice
        uint256 gasBefore = gasleft();
        invoiceAdapterBulla.getInvoiceDetails(unpaidInvoice);
        uint256 gasAfter = gasleft();
        console.log("Unpaid invoice gas:", gasBefore - gasAfter);
        
        // Partially paid invoice
        gasBefore = gasleft();
        invoiceAdapterBulla.getInvoiceDetails(partiallyPaidInvoice);
        gasAfter = gasleft();
        console.log("Partially paid invoice gas:", gasBefore - gasAfter);
    }

    function testCumulativeGasCostAtScale() public {
        console.log("\n=== Cumulative Gas Cost Analysis ===");
        console.log("Simulating the viewPoolStatus() loop overhead\n");

        uint256[] memory testSizes = new uint256[](5);
        testSizes[0] = 10;
        testSizes[1] = 25;
        testSizes[2] = 50;
        testSizes[3] = 100;
        testSizes[4] = 200;

        for (uint256 t = 0; t < testSizes.length; t++) {
            uint256 numInvoices = testSizes[t];
            uint256[] memory invoiceIds = new uint256[](numInvoices);
            
            // Create invoices WITH late fees
            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                invoiceIds[i] = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly
            }
            vm.stopPrank();

            // Simulate the viewPoolStatus loop
            uint256 gasBefore = gasleft();
            for (uint256 i = 0; i < numInvoices; i++) {
                invoiceAdapterBulla.getInvoiceDetails(invoiceIds[i]);
            }
            uint256 gasAfter = gasleft();
            
            uint256 totalGas = gasBefore - gasAfter;
            
            console.log("Active Invoices:", numInvoices);
            console.log("  Total gas:", totalGas);
            console.log("  Gas per invoice:", totalGas / numInvoices);
            console.log("  Estimated cost @ 50 gwei:", (totalGas * 50) / 1e9, "ETH (in wei)");
            console.log("");
        }
    }

    function testViewPoolStatusVsReconcileOverhead() public {
        console.log("\n=== viewPoolStatus() vs reconcileActivePaidInvoices() Overhead ===\n");

        uint256[] memory testSizes = new uint256[](4);
        testSizes[0] = 10;
        testSizes[1] = 25;
        testSizes[2] = 50;
        testSizes[3] = 100;

        for (uint256 t = 0; t < testSizes.length; t++) {
            uint256 numInvoices = testSizes[t];
            
            // Setup: deposit funds and create/approve/fund invoices
            uint256 depositAmount = numInvoices * 200000;
            vm.startPrank(alice);
            bullaFactoring.deposit(depositAmount, alice);
            vm.stopPrank();

            vm.startPrank(bob);
            for (uint256 i = 0; i < numInvoices; i++) {
                uint256 invoiceId = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR late fee
                vm.stopPrank();
                
                vm.startPrank(underwriter);
                bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, minDays, 0);
                vm.stopPrank();
                
                vm.startPrank(bob);
                IERC721(address(bullaInvoice)).approve(address(bullaFactoring), invoiceId); // Approve BullaInvoice NFT
                bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            }
            vm.stopPrank();

            // Measure viewPoolStatus (just checking invoices)
            uint256 gasBefore = gasleft();
            bullaFactoring.viewPoolStatus();
            uint256 gasAfter = gasleft();
            uint256 viewPoolStatusGas = gasBefore - gasAfter;

            // Measure reconcileActivePaidInvoices (checking + processing)
            gasBefore = gasleft();
            bullaFactoring.reconcileActivePaidInvoices();
            gasAfter = gasleft();
            uint256 reconcileGas = gasBefore - gasAfter;

            uint256 processingOverhead = reconcileGas - viewPoolStatusGas;
            
            console.log("Active Invoices:", numInvoices);
            console.log("  viewPoolStatus() gas:", viewPoolStatusGas);
            console.log("  reconcileActivePaidInvoices() gas:", reconcileGas);
            console.log("  Processing overhead:", processingOverhead);
            console.log("  % overhead:", (processingOverhead * 100) / viewPoolStatusGas, "%");
            console.log("");
        }
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
        asset.approve(address(bullaClaim), 1000000);
        for (uint256 i = 0; i < numPaid; i++) {
            bullaClaim.payClaim(invoiceIds[i], 100000);
        }
        vm.stopPrank();

        console.log("Total invoices:", numInvoices);
        console.log("Paid invoices:", numPaid);
        console.log("Unpaid invoices:", numInvoices - numPaid);
        console.log("");

        // Measure viewPoolStatus (just checking)
        uint256 gasBefore = gasleft();
        (uint256[] memory paidInvoices,) = bullaFactoring.viewPoolStatus();
        uint256 gasAfter = gasleft();
        uint256 viewPoolStatusGas = gasBefore - gasAfter;

        console.log("Found", paidInvoices.length, "paid invoices");
        console.log("viewPoolStatus() gas:", viewPoolStatusGas);

        // Measure reconcileActivePaidInvoices (checking + processing payments)
        gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        gasAfter = gasleft();
        uint256 reconcileGas = gasBefore - gasAfter;

        console.log("reconcileActivePaidInvoices() gas:", reconcileGas);
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
        asset.approve(address(bullaClaim), 1000000);
        for (uint256 i = 0; i < numPaid; i++) {
            bullaClaim.payClaim(invoiceIds[i], 100000);
        }
        vm.stopPrank();

        // STEP 1: Measure viewPoolStatus alone
        uint256 gasBefore = gasleft();
        (uint256[] memory paidInvoiceIds,) = bullaFactoring.viewPoolStatus();
        uint256 gasAfter = gasleft();
        uint256 viewPoolStatusGas = gasBefore - gasAfter;

        console.log("Step 1: viewPoolStatus()");
        console.log("  Gas cost:", viewPoolStatusGas);
        console.log("  Found", paidInvoiceIds.length, "paid invoices");
        console.log("");

        // STEP 2: Measure full reconcileActivePaidInvoices (includes both _reconcile and _processQueue)
        gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        gasAfter = gasleft();
        uint256 fullReconcileGas = gasBefore - gasAfter;

        console.log("Step 2: reconcileActivePaidInvoices() [full function]");
        console.log("  Gas cost:", fullReconcileGas);
        console.log("");

        // STEP 3: Calculate _reconcileActivePaidInvoices overhead
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
        console.log("  Queue processing overhead:        ", reconcileWithQueueGas - fullReconcileGas, "gas");
    }

    function testLateFeeImpactOnGasCosts() public {
        console.log("\n=== Late Fee Configuration Impact on Gas Costs ===\n");

        // Test 1: Invoice without late fees (simple claim)
        vm.startPrank(bob);
        uint256 simpleInvoice = createClaim(bob, alice, 100000, dueBy);
        vm.stopPrank();

        uint256 gasBefore = gasleft();
        invoiceAdapterBulla.getInvoiceDetails(simpleInvoice);
        uint256 gasAfter = gasleft();
        uint256 simpleGas = gasBefore - gasAfter;

        console.log("Simple claim (no late fees):");
        console.log("  getInvoiceDetails() gas:", simpleGas);
        console.log("");

        // Test 2: Invoice WITH late fees (BullaInvoice)
        vm.startPrank(bob);
        uint256 lateFeeInvoice = createInvoice(bob, alice, 100000, dueBy, 1000, 12); // 10% APR, monthly
        vm.stopPrank();

        gasBefore = gasleft();
        invoiceAdapterBulla.getInvoiceDetails(lateFeeInvoice);
        gasAfter = gasleft();
        uint256 lateFeeGas = gasBefore - gasAfter;

        console.log("BullaInvoice (with late fees):");
        console.log("  getInvoiceDetails() gas:", lateFeeGas);
        console.log("  Extra gas vs simple:", lateFeeGas > simpleGas ? lateFeeGas - simpleGas : 0);
        console.log("  % increase:", lateFeeGas > simpleGas ? ((lateFeeGas - simpleGas) * 100) / simpleGas : 0, "%");
        console.log("");

        // Test 3: Measure in a loop scenario (realistic)
        uint256 numInvoices = 20;
        uint256[] memory simpleInvoices = new uint256[](numInvoices);
        uint256[] memory lateFeeInvoices = new uint256[](numInvoices);

        vm.startPrank(bob);
        for (uint256 i = 0; i < numInvoices; i++) {
            simpleInvoices[i] = createClaim(bob, alice, 100000, dueBy);
            lateFeeInvoices[i] = createInvoice(bob, alice, 100000, dueBy, 1000, 12);
        }
        vm.stopPrank();

        // Loop through simple invoices
        gasBefore = gasleft();
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceAdapterBulla.getInvoiceDetails(simpleInvoices[i]);
        }
        gasAfter = gasleft();
        uint256 simpleLoopGas = gasBefore - gasAfter;

        // Loop through late fee invoices
        gasBefore = gasleft();
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceAdapterBulla.getInvoiceDetails(lateFeeInvoices[i]);
        }
        gasAfter = gasleft();
        uint256 lateFeeLoopGas = gasBefore - gasAfter;

        console.log("Loop through", numInvoices, "invoices:");
        console.log("  Simple claims total:", simpleLoopGas, "gas");
        console.log("  Late fee invoices total:", lateFeeLoopGas, "gas");
        console.log("  Extra cost for late fees:", lateFeeLoopGas - simpleLoopGas, "gas");
        console.log("  Per-invoice late fee cost:", (lateFeeLoopGas - simpleLoopGas) / numInvoices, "gas");
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
                asset.approve(address(bullaClaim), 1000000);
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

        // COMPONENT 1: viewPoolStatus() - Just checking invoice statuses
        console.log("=== COMPONENT 1: viewPoolStatus() ===");
        uint256 gasBefore = gasleft();
        (uint256[] memory paidInvoiceIds, uint256[] memory impairedInvoiceIds) = bullaFactoring.viewPoolStatus();
        uint256 gasAfter = gasleft();
        uint256 viewPoolStatusGas = gasBefore - gasAfter;
        
        console.log("Gas used:", viewPoolStatusGas);
        console.log("Found paid invoices:", paidInvoiceIds.length);
        console.log("Found impaired invoices:", impairedInvoiceIds.length);
        if (numInvoices > 0) {
            console.log("Gas per active invoice:", viewPoolStatusGas / numInvoices);
        }
        console.log("");

        // COMPONENT 2: Try to isolate _processRedemptionQueue by triggering redemption queue
        console.log("=== COMPONENT 2: Testing with redemption queue activity ===");
        // Measure processRedemptionQueue WITH redemption queue processing
        gasBefore = gasleft();
        bullaFactoring.processRedemptionQueue();
        gasAfter = gasleft();
        uint256 processRedemptionQueueGas = gasBefore - gasAfter;

        console.log("processRedemptionQueue() Gas used:", processRedemptionQueueGas);

        gasBefore = gasleft();
        bullaFactoring.totalAssets();
        gasAfter = gasleft();
        uint256 totalAssetsGas = gasBefore - gasAfter;

        console.log("totalAssets() Gas used:", totalAssetsGas);

        gasBefore = gasleft();
        bullaFactoring.calculateRealizedGainLoss();
        gasAfter = gasleft();
        uint256 calculateRealizedGainLossGas = gasBefore - gasAfter;

        console.log("calculateRealizedGainLoss() Gas used:", calculateRealizedGainLossGas);
       
        gasBefore = gasleft();
        bullaFactoring.maxRedeem();
        gasAfter = gasleft();
        uint256 maxRedeemGas = gasBefore - gasAfter;

        console.log("maxRedeem() Gas used:", maxRedeemGas);
        console.log("");

        // COMPONENT 3: Full reconcileActivePaidInvoices() (includes _reconcile + _processQueue)
        console.log("=== COMPONENT 3: reconcileActivePaidInvoices() ===");
        gasBefore = gasleft();
        bullaFactoring.reconcileActivePaidInvoices();
        gasAfter = gasleft();

        uint256 fullReconcileGas = gasBefore - gasAfter;
        
        console.log("Gas used:", fullReconcileGas);
        console.log("Overhead vs viewPoolStatus:", fullReconcileGas - viewPoolStatusGas, "gas");
        console.log("Overhead percentage:", ((fullReconcileGas - viewPoolStatusGas) * 100) / viewPoolStatusGas, "%");
        console.log("");

        uint256 reconcileOverhead = fullReconcileGas - processRedemptionQueueGas;

        console.log("Gas with queue processing:", processRedemptionQueueGas);
        console.log("Queue reconcile overhead:", reconcileOverhead, "gas");
        console.log("");

        // FINAL BREAKDOWN
        string memory breakdownTitle = numInvoices == 0 
            ? "=== BASELINE COSTS (0 active invoices) ===" 
            : "=== FINAL BREAKDOWN ===";
        console.log(breakdownTitle);
        console.log("1. viewPoolStatus():", viewPoolStatusGas, "gas");
        
        // Handle potential underflow for reconcile logic calculation
        uint256 reconcileLogicGas = 0;
        if (fullReconcileGas > viewPoolStatusGas + processRedemptionQueueGas) {
            reconcileLogicGas = fullReconcileGas - viewPoolStatusGas - processRedemptionQueueGas;
        } else if (fullReconcileGas > viewPoolStatusGas) {
            reconcileLogicGas = fullReconcileGas - viewPoolStatusGas;
            console.log("Note: _processRedemptionQueue appears to overlap with reconcile logic");
        }
        
        console.log("2. _reconcileActivePaidInvoices logic:", reconcileLogicGas, "gas"); 
        console.log("3. _processRedemptionQueue:", processRedemptionQueueGas, "gas");
        console.log("Total:", fullReconcileGas, "gas");
        console.log("");
        
        if (numInvoices > 0) {
            console.log("Cost per active invoice:");
            console.log("  viewPoolStatus:", viewPoolStatusGas / numInvoices, "gas/invoice");
            console.log("  reconcile overhead:", reconcileLogicGas / numInvoices, "gas/invoice");
            if (processRedemptionQueueGas > 0) {
                console.log("  queue processing:", processRedemptionQueueGas, "gas (fixed cost)");
            }
        } else {
            console.log("These are the FIXED COSTS regardless of invoice count.");
        }
    }

    function testThreeComponentGasBreakdown() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN ===");
        console.log("Measuring: viewPoolStatus, _reconcileActivePaidInvoices, _processRedemptionQueue\n");
        _measureThreeComponentGasBreakdown(30, 5);
    }

    function testThreeComponentGasBreakdownWithZeroInvoices() public {
        console.log("\n=== THREE COMPONENT GAS BREAKDOWN - ZERO ACTIVE INVOICES ===");
        console.log("Measuring baseline costs when no invoices are active\n");
        _measureThreeComponentGasBreakdown(0, 0);
    }

    function testScalingOfThreeComponents() public {
        console.log("\n=== SCALING OF THREE COMPONENTS ===\n");

        uint256[] memory testSizes = new uint256[](4);
        testSizes[0] = 10;
        testSizes[1] = 20;
        testSizes[2] = 40;
        testSizes[3] = 80;

        for (uint256 t = 0; t < testSizes.length; t++) {
            uint256 numInvoices = testSizes[t];
            
            // Fresh setup for each test size
            uint256 depositAmount = numInvoices * 200000;
            vm.startPrank(alice);
            bullaFactoring.deposit(depositAmount, alice);
            vm.stopPrank();

            // Create and fund invoices
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

            console.log("=== Test Size:", numInvoices, "invoices ===");

            // Measure viewPoolStatus
            uint256 gasBefore = gasleft();
            bullaFactoring.viewPoolStatus();
            uint256 gasAfter = gasleft();
            uint256 viewPoolGas = gasBefore - gasAfter;

            // Measure full reconcile
            gasBefore = gasleft();
            bullaFactoring.reconcileActivePaidInvoices();
            gasAfter = gasleft();
            uint256 reconcileGas = gasBefore - gasAfter;

            uint256 reconcileOverhead = reconcileGas - viewPoolGas;

            console.log("  viewPoolStatus():", viewPoolGas, "gas");
            console.log("  reconcileActivePaidInvoices():", reconcileGas, "gas");
            console.log("  reconcile overhead:", reconcileOverhead, "gas");
            console.log("  % overhead:", (reconcileOverhead * 100) / viewPoolGas, "%");
            console.log("  Gas per invoice (view):", viewPoolGas / numInvoices);
            console.log("  Gas per invoice (reconcile):", reconcileGas / numInvoices);
            console.log("");
        }
    }
}

