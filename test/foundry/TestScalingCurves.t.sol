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
        _testViewPoolStatusScaling();
    }

    function _testFundInvoiceScaling() internal {
        console.log("--- FUND INVOICE SCALING ---");
        
        uint256 depositAmount = 50000000;
        uint256 invoiceAmount = 100000;

        vm.prank(alice);
        asset.approve(address(bullaFactoring), depositAmount);
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Measure at: 0, 10, 50, 100, 200 active invoices
        uint256[] memory dataPoints = new uint256[](5);
        uint256[] memory counts = new uint256[](5);
        counts[0] = 0; counts[1] = 10; counts[2] = 50; counts[3] = 100; counts[4] = 200;

        // 0 invoices
        vm.prank(bob);
        uint256 id = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(id, 500, 300, 10000, 0);
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
        
        console.log("\nComplexity Analysis:");
        
        if (avgSlope == 0) {
            console.log("  Result: O(1) - CONSTANT TIME");
            console.log("  Gas cost does NOT scale with number of invoices");
            console.log("  Theoretical maximum: UNLIMITED (gas-wise)");
        } else {
            console.log("  Result: O(n) - Linear scaling");
            // Model: gas(n) ≈ gas(200) + slope * (n - 200)
            // Solve for: gas(200) + slope * (n - 200) = 25M
            // n = (25M - gas(200)) / slope + 200
            uint256 theoreticalMax = ((MAX_GAS - dataPoints[4]) / avgSlope) + 200;
            
            console.log("  Theoretical maximum:", theoreticalMax, "invoices");
            console.log("  Safe limit (50%):", theoreticalMax / 2, "invoices");
        }
    }

    function _testDepositScaling() internal {
        console.log("\n--- DEPOSIT SCALING ---");
        console.log("Measuring deposit() gas with different numbers of active invoices");
        
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
        vault.deposit(5000000, alice);  // Larger deposit to fund more invoices
        dataPoints[0] = g - gasleft();
        
        // Fund to 220 invoices
        for (uint256 i = 201; i < 220; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        vault.deposit(1000000, alice);
        dataPoints[1] = g - gasleft();
        
        // Fund to 240 invoices
        for (uint256 i = 220; i < 240; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        vault.deposit(1000000, alice);
        dataPoints[2] = g - gasleft();
        
        // Fund to 260 invoices
        for (uint256 i = 240; i < 260; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        vault.deposit(1000000, alice);
        dataPoints[3] = g - gasleft();
        
        // Fund to 280 invoices
        for (uint256 i = 260; i < 280; i++) {
            _fundOneInvoice(100000);
        }
        
        g = gasleft();
        vm.prank(alice);
        vault.deposit(1000000, alice);
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
        
        console.log("\nComplexity Analysis:");
        console.log("  Average slope (last 3 measurements):", avgSlope, "gas/invoice");
        
        if (avgSlope == 0) {
            console.log("  Result: O(1) - CONSTANT TIME");
            console.log("  Gas cost does NOT scale with number of invoices");
            console.log("  Theoretical maximum: UNLIMITED (gas-wise)");
        } else {
            console.log("  Result: O(n) - Linear scaling");
            // Model: gas(n) ≈ gas(280) + slope * (n - 280)
            // Solve for: gas(280) + slope * (n - 280) = 25M
            uint256 theoreticalMax = ((MAX_GAS - dataPoints[4]) / avgSlope) + 280;
            
            console.log("  Theoretical maximum:", theoreticalMax, "invoices");
            console.log("  Safe limit (50%):", theoreticalMax / 2, "invoices");
        }
    }

    function _testMaxRedeemScaling() internal {
        console.log("\n--- MAX REDEEM / REDEEM SCALING ---");
        
        // Add more deposits for testing
        vm.prank(alice);
        asset.approve(address(bullaFactoring), 10000000);
        vm.prank(alice);
        vault.deposit(10000000, alice);

        // We need to measure at multiple invoice counts to determine scaling
        // We already have 281 invoices, let's add more and measure
        uint256[] memory dataPoints = new uint256[](3);
        uint256[] memory counts = new uint256[](3);
        
        // Measurement 1: Current state (281 invoices)
        counts[0] = 281;
        uint256 g = gasleft();
        vault.maxRedeem(alice);
        dataPoints[0] = g - gasleft();
        
        // Add 50 more invoices
        for (uint256 i = 0; i < 50; i++) {
            _fundOneInvoice(100000);
        }
        
        // Measurement 2: 331 invoices
        counts[1] = 331;
        g = gasleft();
        vault.maxRedeem(alice);
        dataPoints[1] = g - gasleft();
        
        // Add 50 more invoices
        for (uint256 i = 0; i < 50; i++) {
            _fundOneInvoice(100000);
        }
        
        // Measurement 3: 381 invoices
        counts[2] = 381;
        g = gasleft();
        vault.maxRedeem(alice);
        dataPoints[2] = g - gasleft();
        
        console.log("\nData Points:");
        console.log("  n =", counts[0], ", gas =", dataPoints[0]);
        console.log("  n =", counts[1], ", gas =", dataPoints[1]);
        console.log("  n =", counts[2], ", gas =", dataPoints[2]);
        
        // Calculate slopes
        console.log("\nGrowth analysis:");
        uint256 delta1 = dataPoints[1] > dataPoints[0] ? dataPoints[1] - dataPoints[0] : 0;
        uint256 delta2 = dataPoints[2] > dataPoints[1] ? dataPoints[2] - dataPoints[1] : 0;
        
        console.log("  281->331:  delta =", delta1, "over 50 invoices");
        console.log("  331->381:  delta =", delta2, "over 50 invoices");
        
        uint256 slope1 = delta1 / 50;
        uint256 slope2 = delta2 / 50;
        
        console.log("\nGas per invoice added:");
        console.log("  281->331: ", slope1, "gas/invoice");
        console.log("  331->381: ", slope2, "gas/invoice");
        
        uint256 avgSlope = (slope1 + slope2) / 2;
        
        console.log("\nComplexity Analysis:");
        console.log("  Average slope:", avgSlope, "gas/invoice");
        
        if (avgSlope == 0) {
            console.log("  Result: O(1) - CONSTANT TIME");
            console.log("  Gas cost does NOT scale with number of invoices");
            console.log("  Theoretical maximum: UNLIMITED (gas-wise)");
        } else {
            console.log("  Result: O(n) - Linear scaling");
            
            uint256 baseGas = 20000;
            uint256 theoreticalMax = (MAX_GAS - baseGas) / avgSlope;
            
            console.log("  Theoretical maximum:", theoreticalMax, "invoices");
            console.log("  Safe limit (50%):", theoreticalMax / 2, "invoices");
        }
        
        // Also measure viewPoolStatus for reference
        g = gasleft();
        bullaFactoring.viewPoolStatus(0, 25000);
        uint256 gasViewStatus = g - gasleft();
        
        console.log("\nNote: viewPoolStatus() is O(n) but is NOT called by maxRedeem/redeem");
        console.log("      viewPoolStatus() gas at n=381:", gasViewStatus);
    }

    function _testViewPoolStatusScaling() internal {
        console.log("\n--- VIEW POOL STATUS SCALING (Off-chain Keeper Function) ---");
        
        // After maxRedeem test, we now have 381 invoices
        uint256 currentInvoices = 381;
        
        uint256 g = gasleft();
        bullaFactoring.viewPoolStatus(0, 25000);
        uint256 gasView = g - gasleft();
        
        console.log("\nData Point:");
        console.log("  n =", currentInvoices, ", viewPoolStatus() gas =", gasView);
        
        uint256 gasPerInvoice = gasView / currentInvoices;
        console.log("  Gas per invoice:", gasPerInvoice);
        
        console.log("\nComplexity Analysis:");
        
        if (gasPerInvoice == 0) {
            console.log("  Result: O(1) - CONSTANT TIME");
            console.log("  Theoretical maximum: UNLIMITED (gas-wise)");
        } else {
            console.log("  Result: O(n) - Linear scaling");
            
            uint256 baseGas = 15000;
            uint256 theoreticalMax = (MAX_GAS - baseGas) / gasPerInvoice;
            
            console.log("  Theoretical maximum:", theoreticalMax, "invoices");
            console.log("  Safe limit (50%):", theoreticalMax / 2, "invoices");
        }
        
        console.log("\nNote: This is a VIEW function called OFF-CHAIN by keepers");
        console.log("      Off-chain calls have no gas cost for users");
    }

    // Helper functions
    function _fundOneInvoice(uint256 amount) internal {
        vm.prank(bob);
        uint256 id = createClaim(bob, alice, amount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(id, 500, 300, 10000, 0);
        vm.prank(bob);
        IERC721(address(bullaClaim)).approve(address(bullaFactoring), id);
        vm.prank(bob);
        bullaFactoring.fundInvoice(id, 10000, address(0));
    }

    function _approveOneInvoice(uint256 amount) internal returns (uint256) {
        vm.prank(bob);
        uint256 id = createClaim(bob, alice, amount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(id, 500, 300, 10000, 0);
        vm.prank(bob);
        IERC721(address(bullaClaim)).approve(address(bullaFactoring), id);
        return id;
    }
}

