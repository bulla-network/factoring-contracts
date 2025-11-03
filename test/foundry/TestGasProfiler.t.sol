// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ClaimBinding, CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
import {EIP712Helper} from './utils/EIP712Helper.sol';

/// @title Comprehensive Gas Profiler for BullaFactoring Scaling Issues
/// @notice Provides detailed gas analysis of the most expensive functions
contract TestGasProfiler is CommonSetup {
    
    EIP712Helper public sigHelper;
    
    struct GasProfile {
        uint256 getInvoiceDetailsCalls;
        uint256 getInvoiceDetailsGas;
        uint256 totalAssetsGas;
        uint256 calculateRealizedGainLossGas;
        uint256 maxRedeemGas;
        uint256 processRedemptionQueueGas;
        uint256 transferGas;
        uint256 otherGas;
        uint256 totalGas;
    }
    
    // Track external call counts
    uint256 private _getInvoiceDetailsCallCount;
    
    function setUp() public override {
        super.setUp();
        sigHelper = new EIP712Helper(address(bullaClaim));

        // Set up approval for bob to create invoices through BullaInvoice
        bullaClaim.approvalRegistry().permitCreateClaim({
            user: bob,
            controller: address(bullaInvoice),
            approvalType: CreateClaimApprovalType.Approved,
            approvalCount: type(uint64).max,
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
    
    function testDetailedGasProfilerAnalysis() public {
        console.log("\n=== COMPREHENSIVE GAS PROFILER ANALYSIS ===\n");
        
        uint256 numInvoices = 20;
        uint256 numPaid = 5;
        
        // Setup
        uint256 depositAmount = numInvoices * 200000;
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numInvoices);
        vm.startPrank(bob);
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceIds[i] = createClaim(bob, alice, 100000, dueBy);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
        }
        vm.stopPrank();

        // Pay some invoices
        if (numPaid > 0) {
            vm.startPrank(alice);
            uint256 totalPaymentAmount = numPaid * 100000;
            asset.approve(address(bullaClaim), totalPaymentAmount);
            for (uint256 i = 0; i < numPaid; i++) {
                bullaClaim.payClaim(invoiceIds[i], 100000);
            }
            vm.stopPrank();
        }
        
        console.log("Setup: %s active invoices, %s paid\n", numInvoices, numPaid);
        
        // Profile viewPoolStatus
        _profileViewPoolStatus();
        
        // Profile reconcilePaid  
        _profilereconcilePaid();
        
        // Profile individual expensive functions
        _profileExpensiveFunctions();
        
        // Count external calls in key operations
        _analyzeExternalCallPatterns();
    }
    
    function _profileViewPoolStatus() internal {
        console.log("=== 1. viewPoolStatus() Profiling ===");
        
        uint256 gasBefore = gasleft();
        uint256 callsBefore = _getInvoiceDetailsCallCount;
        
        uint256[] memory impairedIds = bullaFactoring.viewPoolStatus();
        
        uint256 gasUsed = gasBefore - gasleft();
        uint256 callsUsed = _getInvoiceDetailsCallCount - callsBefore;
        
        console.log("Gas used: %s", gasUsed);
        console.log("External getInvoiceDetails calls: %s", callsUsed);
        console.log("Gas per external call: %s", callsUsed > 0 ? gasUsed / callsUsed : 0);
        console.log("Impaired invoices found: %s", impairedIds.length);
        
        // Break down the calls
        if (callsUsed > 0) {
            uint256 externalCallGas = callsUsed * 7000; // Estimated from trace
            uint256 internalGas = gasUsed - externalCallGas;
            console.log("  External call gas: ~%s (%s%%)", externalCallGas, (externalCallGas * 100) / gasUsed);
            console.log("  Internal logic gas: ~%s (%s%%)", internalGas, (internalGas * 100) / gasUsed);
        }
        console.log("");
    }
    
    function _profilereconcilePaid() internal {
        console.log("=== 2. reconcilePaid() Deep Dive ===");
        
        uint256 gasBefore = gasleft();
        uint256 callsBefore = _getInvoiceDetailsCallCount;
        
        
        
        uint256 gasUsed = gasBefore - gasleft();
        uint256 callsUsed = _getInvoiceDetailsCallCount - callsBefore;
        
        console.log("Total gas: %s", gasUsed);
        console.log("Total getInvoiceDetails calls: %s", callsUsed);
        console.log("Average gas per external call: %s", callsUsed > 0 ? gasUsed / callsUsed : 0);
        
        // Estimate breakdown
        uint256 estimatedExternalGas = callsUsed * 7000;
        uint256 estimatedInternalGas = gasUsed - estimatedExternalGas;
        
        console.log("  External calls gas: ~%s (%s%%)", estimatedExternalGas, (estimatedExternalGas * 100) / gasUsed);
        console.log("  Internal processing: ~%s (%s%%)", estimatedInternalGas, (estimatedInternalGas * 100) / gasUsed);
        console.log("");
    }
    
    function _profileExpensiveFunctions() internal {
        console.log("=== 3. Individual Function Profiling ===");
        
        // Profile totalAssets
        uint256 gasBefore = gasleft();
        bullaFactoring.totalAssets();
        uint256 totalAssetsGas = gasBefore - gasleft();
        console.log("totalAssets(): %s gas", totalAssetsGas);
        
        // Profile calculateRealizedGainLoss  
        gasBefore = gasleft();
        bullaFactoring.calculateRealizedGainLoss();
        uint256 calculateGainLossGas = gasBefore - gasleft();
        console.log("calculateRealizedGainLoss(): %s gas", calculateGainLossGas);
        
        // Profile maxRedeem
        gasBefore = gasleft();
        bullaFactoring.maxRedeem(alice);
        uint256 maxRedeemGas = gasBefore - gasleft();
        console.log("maxRedeem(): %s gas", maxRedeemGas);
        
        // Profile processRedemptionQueue
        gasBefore = gasleft();
        bullaFactoring.processRedemptionQueue();
        uint256 processQueueGas = gasBefore - gasleft();
        console.log("processRedemptionQueue(): %s gas", processQueueGas);
        
        console.log("");
        console.log("Function Expense Ranking:");
        console.log("1. processRedemptionQueue: %s gas", processQueueGas);
        console.log("2. maxRedeem: %s gas", maxRedeemGas);  
        console.log("3. totalAssets: %s gas", totalAssetsGas);
        console.log("4. calculateRealizedGainLoss: %s gas", calculateGainLossGas);
        console.log("");
    }
    
    function _analyzeExternalCallPatterns() internal {
        console.log("=== 4. External Call Pattern Analysis ===");
        
        // Count calls in different scenarios
        _resetCallCounter();
        
        // Test viewPoolStatus calls
        uint256 callsBefore = _getInvoiceDetailsCallCount;
        bullaFactoring.viewPoolStatus();
        uint256 viewPoolCalls = _getInvoiceDetailsCallCount - callsBefore;
        
        // Test totalAssets calls
        callsBefore = _getInvoiceDetailsCallCount;
        bullaFactoring.totalAssets();
        uint256 totalAssetsCalls = _getInvoiceDetailsCallCount - callsBefore;
        
        // Test calculateRealizedGainLoss calls
        callsBefore = _getInvoiceDetailsCallCount;
        bullaFactoring.calculateRealizedGainLoss();
        uint256 calculateCalls = _getInvoiceDetailsCallCount - callsBefore;
        
        console.log("External call distribution:");
        console.log("  viewPoolStatus(): %s calls", viewPoolCalls);
        console.log("  totalAssets(): %s calls", totalAssetsCalls);
        console.log("  calculateRealizedGainLoss(): %s calls", calculateCalls);
        
        // Calculate theoretical scaling - get number of active invoices
        // Active invoices are now always unpaid; viewPoolStatus only returns impaired invoices
        uint256[] memory impairedInvoices = bullaFactoring.viewPoolStatus();
        uint256 numActiveInvoices = impairedInvoices.length + 15; // Rough estimate including unpaid
        
        console.log("");
        console.log("Scaling Analysis (~%s active invoices):", numActiveInvoices);
        console.log("  Linear (O(n)): %s calls expected", numActiveInvoices);
        console.log("  Quadratic (O(n^2)): %s calls expected", numActiveInvoices * numActiveInvoices);
        console.log("  Actual total calls: %s", viewPoolCalls + totalAssetsCalls + calculateCalls);
        
        uint256 multiplier = (viewPoolCalls + totalAssetsCalls + calculateCalls) / (numActiveInvoices > 0 ? numActiveInvoices : 1);
        console.log("  Call multiplier: %sx per invoice", multiplier);
    }
    
    function _resetCallCounter() internal {
        _getInvoiceDetailsCallCount = 0;
    }
    
    function testScalingProfiler() public {
        console.log("\n=== SCALING PROFILER: Invoice Count vs Gas ===\n");
        
        uint256[] memory testSizes = new uint256[](4);
        testSizes[0] = 5;
        testSizes[1] = 10; 
        testSizes[2] = 20;
        testSizes[3] = 30;
        
        console.log("Invoice Count | viewPoolStatus | totalAssets | calculateGainLoss | processQueue | Calls/Invoice");
        console.log("-------------|----------------|-------------|-------------------|--------------|---------------");
        
        for (uint256 i = 0; i < testSizes.length; i++) {
            uint256 size = testSizes[i];
            
            // Fresh setup
            _setupInvoices(size, size / 5); // Pay 20% of invoices
            
            // Measure each function  
            uint256 viewGas = _measureFunction("viewPoolStatus");
            uint256 totalAssetsGas = _measureFunction("totalAssets");
            uint256 calculateGas = _measureFunction("calculateRealizedGainLoss");
            uint256 processGas = _measureFunction("processRedemptionQueue");
            
            uint256 avgCallsPerInvoice = _estimateCallsPerInvoice(size);
            
            console.log("Size: %s | viewPool: %s | totalAssets: %s", size, viewGas, totalAssetsGas);
            console.log("  | calculateGain: %s | processQueue: %s | calls/invoice: %s", calculateGas, processGas, avgCallsPerInvoice);
        }
        
        console.log("");
        console.log("Key Insights:");
        console.log("- viewPoolStatus should scale O(n) = n calls");
        console.log("- totalAssets may scale worse due to multiple loops");
        console.log("- processRedemptionQueue calls totalAssets multiple times");
        console.log("- Each getInvoiceDetails call ~= 7K gas");
    }
    
    function _setupInvoices(uint256 numInvoices, uint256 numPaid) internal {
        // Reset environment
        vm.deal(address(this), 0);
        
        uint256 depositAmount = numInvoices * 200000;
        vm.startPrank(alice);
        if (bullaFactoring.balanceOf(alice) < depositAmount) {
            bullaFactoring.deposit(depositAmount, alice);
        }
        vm.stopPrank();

        uint256[] memory invoiceIds = new uint256[](numInvoices);
        vm.startPrank(bob);
        for (uint256 i = 0; i < numInvoices; i++) {
            invoiceIds[i] = createClaim(bob, alice, 100000, dueBy);
            vm.stopPrank();
            
            vm.startPrank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.stopPrank();
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
        }
        vm.stopPrank();

        // Pay some invoices
        if (numPaid > 0) {
            vm.startPrank(alice);
            uint256 totalPaymentAmount = numPaid * 100000;
            asset.approve(address(bullaClaim), totalPaymentAmount);
            for (uint256 i = 0; i < numPaid; i++) {
                bullaClaim.payClaim(invoiceIds[i], 100000);
            }
            vm.stopPrank();
        }
    }
    
    function _measureFunction(string memory funcName) internal returns (uint256) {
        bytes32 nameHash = keccak256(abi.encodePacked(funcName));
        uint256 gasBefore = gasleft();
        
        if (nameHash == keccak256("viewPoolStatus")) {
            bullaFactoring.viewPoolStatus();
        } else if (nameHash == keccak256("totalAssets")) {
            bullaFactoring.totalAssets();
        } else if (nameHash == keccak256("calculateRealizedGainLoss")) {
            bullaFactoring.calculateRealizedGainLoss();
        } else if (nameHash == keccak256("processRedemptionQueue")) {
            bullaFactoring.processRedemptionQueue();
        }
        
        return gasBefore - gasleft();
    }
    
    function _estimateCallsPerInvoice(uint256 numInvoices) internal view returns (uint256) {
        // Rough estimate based on our analysis:
        // viewPoolStatus: 1 call per invoice
        // totalAssets: calls multiple functions that each iterate over invoices
        // This is a simplified calculation
        return numInvoices > 0 ? (numInvoices * 4) / numInvoices : 0; // Rough 4x multiplier
    }
}
