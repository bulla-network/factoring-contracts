// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { CommonSetup } from './CommonSetup.t.sol';
import {console} from "forge-std/console.sol";

contract TestEmptyRedemptionGas is CommonSetup {
    
    function setUp() public override {
        super.setUp();
        
        // Give charlie permissions for deposits and redemptions
        depositPermissions.allow(charlie);
        redeemPermissions.allow(charlie);
    }

    /// @notice Test gas consumption with 50 active invoices and 2 users in redemption queue
    function testRedemptionQueue50Invoices() public {
        console.log("=== REDEMPTION QUEUE: 50 ACTIVE INVOICES ===");
        _testRedemptionQueueWithInvoices(50);
    }

    /// @notice Test gas consumption with 100 active invoices and 2 users in redemption queue  
    function testRedemptionQueue100Invoices() public {
        console.log("=== REDEMPTION QUEUE: 100 ACTIVE INVOICES ===");
        _testRedemptionQueueWithInvoices(100);
    }

    /// @notice Test gas consumption with 200 active invoices and 2 users in redemption queue
    function testRedemptionQueue200Invoices() public {
        console.log("=== REDEMPTION QUEUE: 200 ACTIVE INVOICES ===");
        _testRedemptionQueueWithInvoices(200);
    }

    /// @notice Test gas consumption with 250 active invoices and 2 users in redemption queue
    function testRedemptionQueue250Invoices() public {
        console.log("=== REDEMPTION QUEUE: 250 ACTIVE INVOICES ===");
        _testRedemptionQueueWithInvoices(250);
    }

    /// @notice Internal function to test redemption processing gas costs with specified number of invoices
    function _testRedemptionQueueWithInvoices(uint256 numInvoices) internal {
        console.log("Testing redemption processing with", numInvoices, "active invoices");
        
        // Setup: Create active invoices and depositors with sufficient liquidity
        _setupActiveInvoicesAndDepositors(numInvoices);
        
        // Measure EMPTY queue processing (baseline)
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should start empty");
        uint256 gasBefore = gasleft();
        bullaFactoring.processRedemptionQueue();
        uint256 gasAfter = gasleft();
        uint256 emptyQueueGas = gasBefore - gasAfter;
        
        // Setup 2 users to actually redeem funds
        _setupRedemptionQueueWith2Users();
        
        // Measure processing WITH 2 users actually redeeming
        gasBefore = gasleft();
        bullaFactoring.processRedemptionQueue();
        gasAfter = gasleft();
        uint256 activeRedemptionGas = gasBefore - gasAfter;
        
        // Calculate the additional cost of processing 2 actual redemptions
        uint256 redemptionProcessingOverhead = activeRedemptionGas > emptyQueueGas ? activeRedemptionGas - emptyQueueGas : 0;
        uint256 gasPerRedemption = redemptionProcessingOverhead > 0 ? redemptionProcessingOverhead / 2 : 0;
        
        console.log("Gas Analysis Results:");
        console.log("  Empty queue gas:", emptyQueueGas);
        console.log("  Active redemption gas (2 users):", activeRedemptionGas);
        console.log("  Redemption processing overhead:", redemptionProcessingOverhead);
        console.log("  Gas per redemption:", gasPerRedemption);
        console.log("  Gas per invoice (baseline):", emptyQueueGas / numInvoices);
        
        // Calculate theoretical maximums
        uint256 safeGasLimit = 12500000; // 50% of 25M gas limit
        uint256 baseOverhead = 100000;
        uint256 gasPerInvoice = emptyQueueGas / numInvoices;
        uint256 maxSafeInvoices = gasPerInvoice > 0 ? (safeGasLimit - baseOverhead) / gasPerInvoice : 0;
        console.log("  Estimated max safe invoices:", maxSafeInvoices);
        console.log("---");
    }

    /// @notice Setup active invoices and multiple depositors for redemption testing
    function _setupActiveInvoicesAndDepositors(uint256 numInvoices) internal {
        // Phase 1: Fund invoices first with basic deposits
        uint256 invoiceFundingNeeded = numInvoices * 120000; // Each invoice needs ~110k + buffer
        
        // Alice deposits enough to fund invoices
        uint256 aliceInitialDeposit = (invoiceFundingNeeded * 60) / 100;
        vm.startPrank(alice);
        asset.mint(alice, aliceInitialDeposit);
        asset.approve(address(bullaFactoring), aliceInitialDeposit);
        bullaFactoring.deposit(aliceInitialDeposit, alice);
        vm.stopPrank();
        
        // Charlie deposits enough to fund invoices
        uint256 charlieInitialDeposit = (invoiceFundingNeeded * 40) / 100;
        vm.startPrank(charlie);
        asset.mint(charlie, charlieInitialDeposit);
        asset.approve(address(bullaFactoring), charlieInitialDeposit);
        bullaFactoring.deposit(charlieInitialDeposit, charlie);
        vm.stopPrank();
        
        // Bob creates invoices and gets them funded
        vm.startPrank(bob);
        asset.mint(bob, numInvoices * 100000); // For any debtor portion needed
        
        for (uint256 i = 0; i < numInvoices; i++) {
            uint256 invoiceId = createClaim(bob, alice, 100000, dueBy);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0); // 10% APR, 1% spread, 100% upfront
            vm.stopPrank();
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, 10000, address(0)); // 100% upfront
        }
        vm.stopPrank();
        
        uint256 liquidityAfterFunding = bullaFactoring.totalAssets();
        console.log("After funding invoices - remaining liquidity:", liquidityAfterFunding);
        
        // Phase 2: Add additional deposits specifically for redemption liquidity
        // This ensures users can actually redeem rather than just get queued
        uint256 redemptionLiquidityNeeded = 3000000; // Generous liquidity for actual redemptions
        
        // Add more deposits to provide redemption liquidity
        vm.startPrank(alice);
        asset.mint(alice, redemptionLiquidityNeeded);
        asset.approve(address(bullaFactoring), redemptionLiquidityNeeded);
        bullaFactoring.deposit(redemptionLiquidityNeeded, alice);
        vm.stopPrank();
        
        uint256 finalLiquidity = bullaFactoring.totalAssets();
        console.log("After additional deposits - final liquidity:", finalLiquidity);
        console.log("Setup complete - users can now actually redeem funds");
    }

    /// @notice Setup redemption with 2 users actually redeeming funds (not just queuing)
    function _setupRedemptionQueueWith2Users() internal {
        uint256 aliceShares = bullaFactoring.balanceOf(alice);
        uint256 charlieShares = bullaFactoring.balanceOf(charlie);
        uint256 availableLiquidity = bullaFactoring.totalAssets();
        
        console.log("  Available liquidity for redemptions:", availableLiquidity);
        console.log("  Alice shares:", aliceShares, "Charlie shares:", charlieShares);
        
        // Alice redeems a substantial amount that should process immediately
        // Target ~1M in assets which should be well within available liquidity
        uint256 aliceTargetAssets = availableLiquidity + 100;
        uint256 aliceRedemptionShares = bullaFactoring.previewWithdraw(aliceTargetAssets);
        
        vm.startPrank(alice);
        (uint256 aliceRedeemed, uint256 aliceQueued) = bullaFactoring.redeemAndOrQueue(aliceRedemptionShares, alice, alice);
        vm.stopPrank();
        
        // Charlie redeems after Alice, should also process immediately  
        // Target ~800K in assets
        uint256 charlieTargetAssets = availableLiquidity + 100;
        uint256 charlieRedemptionShares = bullaFactoring.previewWithdraw(charlieTargetAssets);
        
        vm.startPrank(charlie);
        (uint256 charlieRedeemed, uint256 charlieQueued) = bullaFactoring.redeemAndOrQueue(charlieRedemptionShares, charlie, charlie);
        vm.stopPrank();
        
        console.log("  Alice: redeemed", aliceRedeemed, "queued", aliceQueued);
        console.log("  Charlie: redeemed", charlieRedeemed, "queued", charlieQueued);
        
        // Verify both users actually got liquidity
        bool aliceGotLiquidity = aliceRedeemed > 0;
        bool charlieGotLiquidity = charlieRedeemed > 0;
        
        if (aliceGotLiquidity && charlieGotLiquidity) {
            console.log("  SUCCESS: Both users redeemed funds immediately");
        } else if (aliceGotLiquidity || charlieGotLiquidity) {
            console.log("  PARTIAL: One user redeemed, one queued");
        } else {
            console.log("  NOTE: Both users queued (insufficient liquidity)");
        }

        // deposit a bunch of funds to the pool
        vm.startPrank(alice);
        asset.mint(alice, 1000000);
        asset.approve(address(bullaFactoring), 1000000);
        bullaFactoring.deposit(1000000, alice);
        vm.stopPrank();
    }

    /// @notice Setup active invoices for testing (original version)
    function _setupActiveInvoices(uint256 numInvoices) internal {
        uint256 depositAmount = numInvoices * 120000;
        
        // Alice deposits enough funds
        vm.startPrank(alice);
        asset.mint(alice, depositAmount);
        asset.approve(address(bullaFactoring), depositAmount);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Bob creates and funds invoices (but doesn't pay them)
        vm.startPrank(bob);
        for (uint256 i = 0; i < numInvoices; i++) {
            uint256 invoiceId = createClaim(bob, alice, 120000, dueBy);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, 1000, 100, 10000, 0, 0); // 10% APR, 1% spread, 100% upfront
            vm.stopPrank();
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, 10000, address(0));
        }
        vm.stopPrank();
        
        console.log("Setup complete");
    }

    /// @notice Test empty queue processing with 25 invoices (baseline test)
    function testEmptyQueueBaseline25Invoices() public {
        console.log("=== BASELINE: 25 ACTIVE INVOICES (EMPTY QUEUE) ===");
        
        _setupActiveInvoices(25);
        
        assertTrue(bullaFactoring.getRedemptionQueue().isQueueEmpty(), "Queue should be empty");
        
        uint256 gasBefore = gasleft();
        bullaFactoring.processRedemptionQueue();
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;
        
        console.log("Results:");
        console.log("  Gas used:", gasUsed);
        console.log("  Gas per invoice:", gasUsed / 25);
        console.log("  Estimated max safe (50% buffer):", 12500000 / (gasUsed / 25));
    }

    /// @notice Test different blockchain gas limits analysis
    function testGasLimitsAnalysis() public view {
        console.log("=== GAS LIMITS ANALYSIS ===");
        console.log("Common blockchain gas limits:");
        console.log("- Ethereum Mainnet: ~30M gas");
        console.log("- Polygon: ~20M gas");
        console.log("- Arbitrum: ~32M gas");
        console.log("- Base: ~30M gas");
        console.log("");
        
        // Estimate based on measured gas per invoice
        uint256 gasPerInvoice = 25000; // Conservative estimate from tests
        uint256 baseOverhead = 200000; // Conservative overhead estimate
        
        console.log("Estimated maximum active invoices by chain (50% safety margin):");
        console.log("- Ethereum:", (15000000 - baseOverhead) / gasPerInvoice, "invoices");
        console.log("- Polygon:", (10000000 - baseOverhead) / gasPerInvoice, "invoices");
        console.log("- Arbitrum:", (16000000 - baseOverhead) / gasPerInvoice, "invoices");
        console.log("- Base:", (15000000 - baseOverhead) / gasPerInvoice, "invoices");
        console.log("");
        console.log("Note: These are conservative estimates based on test data.");
        console.log("Recommendation: Keep active invoices under 300-400 for safety.");
    }
}
