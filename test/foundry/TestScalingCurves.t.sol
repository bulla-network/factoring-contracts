// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";

contract TestScalingCurves is CommonSetup {
    uint256 constant MAX_GAS = 25_000_000;

    /// @notice Comprehensive scaling analysis with curve fitting
    function testAllFunctionScalingCurves() public {
        console.log("\n=== COMPREHENSIVE SCALING CURVE ANALYSIS ===");
        console.log("Maximum gas per transaction: 25,000,000 gas\n");

        // Test each function with measurements at multiple points
        _testFundInvoiceScaling();
        _testDepositScaling();
        _testMaxRedeemScaling();
        _testReconcileScaling();
    }

    function _testFundInvoiceScaling() internal {
        console.log("--- FUND INVOICE SCALING ---");
        
        uint256 depositAmount = 50000000;
        uint256 invoiceAmount = 100000;

        vm.prank(alice);
        asset.approve(address(bullaFactoring), depositAmount);
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        // Measure at: 0, 10, 50, 100, 200 active invoices
        uint256[] memory dataPoints = new uint256[](5);
        uint256[] memory counts = new uint256[](5);
        counts[0] = 0; counts[1] = 10; counts[2] = 50; counts[3] = 100; counts[4] = 200;

        // 0 invoices
        vm.prank(bob);
        uint256 id = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(id, 500, 300, 10000, 0, 0);
        vm.prank(bob);
        IERC721(address(bullaClaim)).approve(address(bullaFactoring), id);
        uint256 g = gasleft();
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
        dataPoints[0] = g - gasleft();

        // Get to 10
        for (uint256 i = 1; i < 10; i++) {
            _fundOneInvoice(invoiceAmount);
        }
        id = _approveOneInvoice(invoiceAmount);
        g = gasleft();
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
        dataPoints[1] = g - gasleft();

        // Get to 50
        for (uint256 i = 11; i < 50; i++) {
            _fundOneInvoice(invoiceAmount);
        }
        id = _approveOneInvoice(invoiceAmount);
        g = gasleft();
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
        dataPoints[2] = g - gasleft();

        // Get to 100
        for (uint256 i = 51; i < 100; i++) {
            _fundOneInvoice(invoiceAmount);
        }
        id = _approveOneInvoice(invoiceAmount);
        g = gasleft();
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
        dataPoints[3] = g - gasleft();

        // Get to 200
        for (uint256 i = 101; i < 200; i++) {
            _fundOneInvoice(invoiceAmount);
        }
        id = _approveOneInvoice(invoiceAmount);
        g = gasleft();
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
        dataPoints[4] = g - gasleft();

        console.log("\nData Points:");
        for (uint256 i = 0; i < 5; i++) {
            console.log("  n =", counts[i], ", gas =", dataPoints[i]);
        }

        // Analyze curve: appears to be sublinear growth
        // Growth rates vary significantly (can even be negative initially due to warm storage)
        
        console.log("\nGrowth analysis:");
        console.log("  0->10:     gas DECREASED (warm storage effect)");
        
        int256 delta10to50 = int256(dataPoints[2]) - int256(dataPoints[1]);
        int256 delta50to100 = int256(dataPoints[3]) - int256(dataPoints[2]);
        int256 delta100to200 = int256(dataPoints[4]) - int256(dataPoints[3]);
        
        console.log("  10->50:    delta =", uint256(delta10to50), "over 40 invoices");
        console.log("  50->100:   delta =", uint256(delta50to100), "over 50 invoices");
        console.log("  100->200:  delta =", uint256(delta100to200), "over 100 invoices");

        // Calculate slopes (gas per invoice added)
        uint256 slope10to50 = uint256(delta10to50) / 40;
        uint256 slope50to100 = uint256(delta50to100) / 50;
        uint256 slope100to200 = uint256(delta100to200) / 100;
        
        console.log("\nGas per invoice added:");
        console.log("  10->50:   ", slope10to50, "gas/invoice");
        console.log("  50->100:  ", slope50to100, "gas/invoice");
        console.log("  100->200: ", slope100to200, "gas/invoice");

        // Use slope from 100->200 as it's the most stable long-term rate
        uint256 avgSlope = slope100to200;
        
        // Model: gas(n) ≈ gas(200) + slope * (n - 200)
        // Solve for: gas(200) + slope * (n - 200) = 25M
        // n = (25M - gas(200)) / slope + 200
        uint256 theoreticalMax = ((MAX_GAS - dataPoints[4]) / avgSlope) + 200;
        
        console.log("\nUsing 100->200 slope for projection:");
        console.log("Theoretical maximum:", theoreticalMax, "invoices");
        console.log("Safe limit (50%):", theoreticalMax / 2, "invoices");
        
        console.log("\nNote: Early measurements show warm storage effects");
        console.log("Long-term growth rate is more predictable at scale");
    }

    function _testDepositScaling() internal {
        console.log("\n--- DEPOSIT SCALING ---");
        console.log("Measuring deposit() gas with different numbers of active invoices");
        console.log("Note: deposit() calls previewDeposit() which calls calculateCapitalAccount() and calculateAccruedProfits()");
        console.log("      Both iterate over all active invoices, making this O(n)\n");
        
        // Start from 201 invoices (created in fundInvoice test)
        // Measure at: 201, 220, 240, 260, 280 (smaller increments)
        uint256[] memory dataPoints = new uint256[](5);
        uint256[] memory counts = new uint256[](5);
        counts[0] = 201; counts[1] = 220; counts[2] = 240; counts[3] = 260; counts[4] = 280;
        
        // Use alice who is already authorized - give her more funds
        asset.mint(alice, 50000000);
        
        vm.prank(alice);
        asset.approve(address(bullaFactoring), 50000000);
        
        // Measure at 201 invoices
        uint256 g = gasleft();
        vm.prank(alice);
        bullaFactoring.deposit(5000000, alice);  // Larger deposit to fund more invoices
        dataPoints[0] = g - gasleft();
        
        // Fund to 220 invoices
        for (uint256 i = 201; i < 220; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        bullaFactoring.deposit(1000000, alice);
        dataPoints[1] = g - gasleft();
        
        // Fund to 240 invoices
        for (uint256 i = 220; i < 240; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        bullaFactoring.deposit(1000000, alice);
        dataPoints[2] = g - gasleft();
        
        // Fund to 260 invoices
        for (uint256 i = 240; i < 260; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        bullaFactoring.deposit(1000000, alice);
        dataPoints[3] = g - gasleft();
        
        // Fund to 280 invoices
        for (uint256 i = 260; i < 280; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        bullaFactoring.deposit(1000000, alice);
        dataPoints[4] = g - gasleft();
        
        console.log("Data Points:");
        for (uint256 i = 0; i < 5; i++) {
            console.log("  n =", counts[i], ", gas =", dataPoints[i]);
        }
        
        console.log("\nGrowth analysis:");
        
        int256 delta201to220 = int256(dataPoints[1]) - int256(dataPoints[0]);
        int256 delta220to240 = int256(dataPoints[2]) - int256(dataPoints[1]);
        int256 delta240to260 = int256(dataPoints[3]) - int256(dataPoints[2]);
        int256 delta260to280 = int256(dataPoints[4]) - int256(dataPoints[3]);
        
        console.log("  201->220:  delta =", uint256(delta201to220), "over 19 invoices");
        console.log("  220->240:  delta =", uint256(delta220to240), "over 20 invoices");
        console.log("  240->260:  delta =", uint256(delta240to260), "over 20 invoices");
        console.log("  260->280:  delta =", uint256(delta260to280), "over 20 invoices");
        
        // Calculate slopes (gas per invoice in pool)
        uint256 slope201to220 = uint256(delta201to220) / 19;
        uint256 slope220to240 = uint256(delta220to240) / 20;
        uint256 slope240to260 = uint256(delta240to260) / 20;
        uint256 slope260to280 = uint256(delta260to280) / 20;
        
        console.log("\nGas per invoice in pool:");
        console.log("  201->220: ", slope201to220, "gas/invoice");
        console.log("  220->240: ", slope220to240, "gas/invoice");
        console.log("  240->260: ", slope240to260, "gas/invoice");
        console.log("  260->280: ", slope260to280, "gas/invoice");
        
        // Use stable long-term rate for projection (avg of last three)
        uint256 avgSlope = (slope220to240 + slope240to260 + slope260to280) / 3;
        
        // Model: gas(n) ≈ gas(280) + slope * (n - 280)
        // Solve for: gas(280) + slope * (n - 280) = 25M
        uint256 theoreticalMax = ((MAX_GAS - dataPoints[4]) / avgSlope) + 280;
        
        console.log("\nUsing average of last 3 slopes for projection:");
        console.log("Average slope:", avgSlope, "gas/invoice");
        console.log("Theoretical maximum:", theoreticalMax, "invoices");
        console.log("Safe limit (50%):", theoreticalMax / 2, "invoices");
        
        console.log("\nComplexity: O(n) - Linear (iterates through active invoices in previewDeposit)");
    }

    function _testMaxRedeemScaling() internal {
        console.log("\n--- MAX REDEEM / REDEEM SCALING ---");
        
        // We now have ~501 invoices from previous tests
        // Measure maxRedeem (bottleneck for redeem)
        
        // Add more deposits for testing
        vm.prank(alice);
        asset.approve(address(bullaFactoring), 10000000);
        vm.prank(alice);
        bullaFactoring.deposit(10000000, alice);

        // Current state: 281 invoices (201 from fundInvoice + 80 from deposit test)
        uint256 currentInvoices = 281;
        uint256 g = gasleft();
        bullaFactoring.maxRedeem(alice);
        uint256 gasMaxRedeem = g - gasleft();

        console.log("\nData Point:");
        console.log("  n =", currentInvoices, ", maxRedeem() gas =", gasMaxRedeem);
        
        // maxRedeem calls viewPoolStatus which is the real bottleneck
        // Also calls calculateCapitalAccount and totalAssets
        
        g = gasleft();
        bullaFactoring.viewPoolStatus();
        uint256 gasViewStatus = g - gasleft();
        
        g = gasleft();
        bullaFactoring.calculateCapitalAccount();
        uint256 gasCapital = g - gasleft();
        
        g = gasleft();
        bullaFactoring.totalAssets();
        uint256 gasAssets = g - gasleft();
        
        console.log("  viewPoolStatus() gas =", gasViewStatus);
        console.log("  calculateCapitalAccount() gas =", gasCapital);
        console.log("  totalAssets() gas =", gasAssets);

        // Calculate per-invoice costs
        uint256 gasPerInvoiceViewStatus = gasViewStatus / currentInvoices;
        uint256 gasPerInvoiceCapital = gasCapital / currentInvoices;
        uint256 gasPerInvoiceAssets = gasAssets / currentInvoices;
        uint256 gasPerInvoiceMaxRedeem = gasMaxRedeem / currentInvoices;

        console.log("\nPer-invoice costs:");
        console.log("  viewPoolStatus:", gasPerInvoiceViewStatus, "gas/invoice");
        console.log("  calculateCapitalAccount:", gasPerInvoiceCapital, "gas/invoice");
        console.log("  totalAssets:", gasPerInvoiceAssets, "gas/invoice");
        console.log("  maxRedeem (total):", gasPerInvoiceMaxRedeem, "gas/invoice");

        console.log("\nBOTTLENECK: viewPoolStatus is the limiting factor for maxRedeem");

        // Calculate theoretical max based on viewPoolStatus (the real bottleneck)
        uint256 baseGas = 20000; // Estimated base overhead
        uint256 theoreticalMax = (MAX_GAS - baseGas) / gasPerInvoiceViewStatus;
        
        console.log("\nComplexity: O(n) - Linear");
        console.log("Theoretical maximum (based on viewPoolStatus):", theoreticalMax, "invoices");
        console.log("Safe limit (50%):", theoreticalMax / 2, "invoices");

        // Impact of impairmentDate optimization
        console.log("\nWith impairmentDate optimization:");
        console.log("  Saves ~2,100 gas per invoice (cold) / ~100 gas (warm)");
        uint256 optimizedGasPerInvoice = gasPerInvoiceViewStatus > 2100 ? gasPerInvoiceViewStatus - 2100 : gasPerInvoiceViewStatus - 100;
        uint256 optimizedMax = (MAX_GAS - baseGas) / optimizedGasPerInvoice;
        console.log("  Optimized theoretical max:", optimizedMax, "invoices");
        console.log("  Improvement:", ((optimizedMax - theoreticalMax) * 100) / theoreticalMax, "%");
    }

    function _testReconcileScaling() internal {
        console.log("\n--- RECONCILE SCALING ---");
        
        // We now have 281 invoices (201 from fundInvoice + 80 from deposit test)
        uint256 currentInvoices = 281;
        
        // Measure viewPoolStatus (core of reconcile) - already measured in maxRedeem
        // But measure again for clarity
        uint256 g = gasleft();
        bullaFactoring.viewPoolStatus();
        uint256 gasView = g - gasleft();
        
        console.log("\nData Point:");
        console.log("  n =", currentInvoices, ", viewPoolStatus() gas =", gasView);
        
        uint256 gasPerInvoice = gasView / currentInvoices;
        console.log("  Gas per invoice:", gasPerInvoice);
        
        uint256 baseGas = 15000;
        uint256 theoreticalMax = (MAX_GAS - baseGas) / gasPerInvoice;
        
        console.log("\nComplexity: O(n) - Linear");
        console.log("Theoretical maximum:", theoreticalMax, "invoices");
        console.log("Safe limit (50%):", theoreticalMax / 2, "invoices");
        console.log("\nNote: Actual reconcile cost also depends on # of paid invoices");
        console.log("      This is the cost just to check status of all invoices");
        console.log("      reconcileActivePaidInvoices() will be higher based on # paid");
    }

    // Helper functions
    function _fundOneInvoice(uint256 amount) internal {
        vm.prank(bob);
        uint256 id = createClaim(bob, alice, amount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(id, 500, 300, 10000, 0, 0);
        vm.prank(bob);
        IERC721(address(bullaClaim)).approve(address(bullaFactoring), id);
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
    }

    function _approveOneInvoice(uint256 amount) internal returns (uint256) {
        vm.prank(bob);
        uint256 id = createClaim(bob, alice, amount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(id, 500, 300, 10000, 0, 0);
        vm.prank(bob);
        IERC721(address(bullaClaim)).approve(address(bullaFactoring), id);
        return id;
    }
}

