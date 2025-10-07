// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';

contract TestGasCostScaling is CommonSetup {
    event GasMeasurement(uint256 invoiceNumber, uint256 gasUsed);

    function testFundInvoiceGasCostDoesNotScaleWithNumberOfInvoices() public {
        uint256 numberOfInvoices = 50;
        uint256 invoiceAmount = 100000; // $100k per invoice
        upfrontBps = 8000; // 80% upfront
        
        // Deposit enough funds to cover all invoices
        uint256 totalDeposit = invoiceAmount * numberOfInvoices * 2; // 2x to be safe
        vm.startPrank(alice);
        bullaFactoring.deposit(totalDeposit, alice);
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numberOfInvoices);
        uint256[] memory gasUsedPerInvoice = new uint256[](numberOfInvoices);

        // Create and approve all invoices upfront
        vm.startPrank(bob);
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy);
        }
        vm.stopPrank();

        // Approve all invoices
        vm.startPrank(underwriter);
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, 0);
        }
        vm.stopPrank();

        // Fund each invoice individually and measure gas
        vm.startPrank(bob);
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            
            uint256 gasBefore = gasleft();
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            uint256 gasAfter = gasleft();
            
            gasUsedPerInvoice[i] = gasBefore - gasAfter;
            emit GasMeasurement(i + 1, gasUsedPerInvoice[i]);
        }
        vm.stopPrank();

        // Get first and last gas measurements
        uint256 firstGas = gasUsedPerInvoice[0];
        uint256 lastGas = gasUsedPerInvoice[numberOfInvoices - 1];

        // Log the results for visibility
        console.log("First invoice gas used:", firstGas);
        console.log("Last invoice gas used:", lastGas);
        console.log("Number of invoices factored:", numberOfInvoices);

        // Calculate the percentage difference
        uint256 difference;
        uint256 percentageDifference;
        
        if (lastGas > firstGas) {
            difference = lastGas - firstGas;
            percentageDifference = (difference * 100) / firstGas;
            console.log("Gas increased by:", percentageDifference, "%");
        } else {
            difference = firstGas - lastGas;
            percentageDifference = (difference * 100) / firstGas;
            console.log("Gas decreased by:", percentageDifference, "%");
        }

        // Assert that the difference is less than 10%
        assertLt(
            percentageDifference, 
            10, 
            "Gas cost difference between first and last invoice should be less than 10%"
        );

        // Additional logging: print all gas values to see the trend
        console.log("\n=== Gas usage per invoice ===");
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            console.log("Invoice", i + 1, "gas:", gasUsedPerInvoice[i]);
        }

        // Calculate average gas to show overall trend
        uint256 totalGas = 0;
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            totalGas += gasUsedPerInvoice[i];
        }
        uint256 averageGas = totalGas / numberOfInvoices;
        console.log("\nAverage gas used:", averageGas);
    }

    function testFundInvoiceGasCostDetailed() public {
        // This is a more detailed test that checks gas at different intervals
        uint256 numberOfInvoices = 50;
        uint256 invoiceAmount = 100000;
        upfrontBps = 8000;
        
        uint256 totalDeposit = invoiceAmount * numberOfInvoices * 2;
        vm.startPrank(alice);
        bullaFactoring.deposit(totalDeposit, alice);
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numberOfInvoices);
        uint256[] memory gasUsedPerInvoice = new uint256[](numberOfInvoices);

        // Create and approve all invoices
        vm.startPrank(bob);
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy);
        }
        vm.stopPrank();

        vm.startPrank(underwriter);
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, minDays, 0);
        }
        vm.stopPrank();

        // Fund each invoice and measure gas
        vm.startPrank(bob);
        for (uint256 i = 0; i < numberOfInvoices; i++) {
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            
            uint256 gasBefore = gasleft();
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            uint256 gasAfter = gasleft();
            
            gasUsedPerInvoice[i] = gasBefore - gasAfter;
        }
        vm.stopPrank();

        // Check gas at different milestones: 1st, 10th, 25th, and 50th
        uint256 gas1st = gasUsedPerInvoice[0];
        uint256 gas10th = gasUsedPerInvoice[9];
        uint256 gas25th = gasUsedPerInvoice[24];
        uint256 gas50th = gasUsedPerInvoice[49];

        console.log("\n=== Gas at key milestones ===");
        console.log("1st invoice:", gas1st);
        console.log("10th invoice:", gas10th);
        console.log("25th invoice:", gas25th);
        console.log("50th invoice:", gas50th);

        // Check 1st vs 10th
        uint256 diff1to10 = gas10th > gas1st ? 
            ((gas10th - gas1st) * 100) / gas1st : 
            ((gas1st - gas10th) * 100) / gas1st;
        console.log("1st to 10th difference:", diff1to10, "%");
        assertLt(diff1to10, 10, "Gas difference between 1st and 10th should be < 10%");

        // Check 1st vs 25th
        uint256 diff1to25 = gas25th > gas1st ? 
            ((gas25th - gas1st) * 100) / gas1st : 
            ((gas1st - gas25th) * 100) / gas1st;
        console.log("1st to 25th difference:", diff1to25, "%");
        assertLt(diff1to25, 10, "Gas difference between 1st and 25th should be < 10%");

        // Check 1st vs 50th
        uint256 diff1to50 = gas50th > gas1st ? 
            ((gas50th - gas1st) * 100) / gas1st : 
            ((gas1st - gas50th) * 100) / gas1st;
        console.log("1st to 50th difference:", diff1to50, "%");
        assertLt(diff1to50, 10, "Gas difference between 1st and 50th should be < 10%");
    }
}

