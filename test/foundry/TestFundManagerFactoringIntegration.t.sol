// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_1 } from 'contracts/BullaFactoring.sol';
import { BullaFactoringFundManager, IBullaFactoringFundManager } from 'contracts/FactoringFundManager.sol';
import { CommonSetup } from './CommonSetup.t.sol';
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "contracts/interfaces/IBullaFactoring.sol";

/**
 * @title TestFundManagerFactoringIntegration
 * @notice Comprehensive integration tests between FactoringFundManager and BullaFactoring
 * @dev Tests the full workflow from investor commitments through capital calls to invoice factoring
 */
contract TestFundManagerFactoringIntegration is CommonSetup {
    BullaFactoringFundManager public fundManager;
    
    // Test accounts
    address public fundOwner = address(0x1111);
    address public capitalCaller = address(0x2222);
    address public investor1 = address(0x3333);
    address public investor2 = address(0x4444);
    address public investor3 = address(0x5555);
    
    // Test constants
    uint256 public constant MIN_INVESTMENT = 10_000 * 1e6; // 10,000 USDC
    uint256 public constant INVESTOR1_COMMITMENT = 100_000 * 1e6; // 100,000 USDC
    uint256 public constant INVESTOR2_COMMITMENT = 200_000 * 1e6; // 200,000 USDC
    uint256 public constant INVESTOR3_COMMITMENT = 50_000 * 1e6;  // 50,000 USDC
    
    // Events
    event InvestorAllowlisted(address indexed investor, address indexed owner);
    event InvestorCommitment(address indexed investor, uint256 amount);
    event CapitalCallComplete(address[] investors, uint256 callAmount);
    event InvestorInsolvent(address indexed investor, uint256 amountRequested);

    function setUp() public override {
        super.setUp();
        
        // Deploy fund manager
        vm.startPrank(fundOwner);
        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(address(bullaFactoring)),
            _minInvestment: MIN_INVESTMENT,
            _capitalCaller: capitalCaller
        });
        vm.stopPrank();
        
        // Allow fund manager to deposit into factoring pool
        depositPermissions.allow(address(fundManager));
        
        // Setup investors with USDC balances
        _setupInvestor(investor1, INVESTOR1_COMMITMENT);
        _setupInvestor(investor2, INVESTOR2_COMMITMENT);  
        _setupInvestor(investor3, INVESTOR3_COMMITMENT);
    }
    
    function _setupInvestor(address investor, uint256 amount) internal {
        // Mint USDC to investor
        asset.mint(investor, amount);
        
        // Allowlist investor
        vm.prank(fundOwner);
        fundManager.allowlistInvestor(investor);
        
        // Investor approves fund manager
        vm.prank(investor);
        asset.approve(address(fundManager), amount);
    }

    // ============================================
    // 1. Basic Integration Workflow Tests  
    // ============================================

    function testFullWorkflow_CommitmentToCapitalCallToFactoring() public {
        // Step 1: Investors commit capital
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        vm.prank(investor2);
        fundManager.commit(INVESTOR2_COMMITMENT);
        
        // Verify commitments
        assertEq(fundManager.totalCommitted(), INVESTOR1_COMMITMENT + INVESTOR2_COMMITMENT);
        
        // Step 2: Capital call to fund factoring pool
        uint256 callAmount = 150_000 * 1e6; // 150,000 USDC
        
        vm.prank(capitalCaller);
        (uint256 totalCalled, uint256 insolventCount) = fundManager.capitalCall(callAmount);
        
        assertEq(totalCalled, callAmount);
        assertEq(insolventCount, 0);
        
        // Verify fund manager deposited into factoring pool
        assertEq(bullaFactoring.balanceOf(investor1), 50_000 * 1e6); // 50k of 100k commitment (50% call)
        assertEq(bullaFactoring.balanceOf(investor2), 100_000 * 1e6); // 100k of 200k commitment (50% call)
        
        // Step 3: Use factoring pool for invoice factoring
        uint256 invoiceAmount = 80_000 * 1e6;
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        // Verify factoring operation succeeded
        assertGt(fundedAmount, 0);
        assertEq(bullaFactoring.originalCreditors(invoiceId), bob);
    }

    // ============================================
    // 2. Capital Call Driven Factoring Tests
    // ============================================

    function testCapitalCall_TriggersFactoringCapability() public {
        // Initial state: no funds in factoring pool
        assertEq(bullaFactoring.totalAssets(), 0);
        
        // Setup investor commitments
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        // Try to factor invoice without capital - should fail due to insufficient funds
        uint256 invoiceAmount = 80_000 * 1e6;
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringV2_1.InsufficientFunds.selector, 0, 64040000000)); // Should fail due to insufficient funds (0 available, net funded amount required)
        bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        // Capital call to fund the pool
        vm.prank(capitalCaller);
        fundManager.capitalCall(INVESTOR1_COMMITMENT);
        
        // Now factoring should work
        vm.prank(bob);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        assertGt(fundedAmount, 0);
    }

    function testMultipleCapitalCalls_AccumulativeFunding() public {
        // Setup commitments
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        vm.prank(investor2);
        fundManager.commit(INVESTOR2_COMMITMENT);
        
        // First capital call: 50k
        vm.prank(capitalCaller);
        fundManager.capitalCall(50_000 * 1e6);
        
        uint256 poolBalance1 = bullaFactoring.totalAssets();
        assertApproxEqRel(poolBalance1, 50_000 * 1e6, 0.001e18); // 0.1% tolerance
        
        // Second capital call: 100k more
        vm.prank(capitalCaller);
        fundManager.capitalCall(100_000 * 1e6);
        
        uint256 poolBalance2 = bullaFactoring.totalAssets();
        assertApproxEqRel(poolBalance2, 150_000 * 1e6, 0.001e18); // 0.1% tolerance
        
        // Third capital call: remaining 150k
        vm.prank(capitalCaller);
        fundManager.capitalCall(150_000 * 1e6);
        
        uint256 poolBalance3 = bullaFactoring.totalAssets();
        assertApproxEqRel(poolBalance3, 300_000 * 1e6, 0.001e18); // 0.1% tolerance
        
        // Verify all commitments are now exhausted (allow for small rounding remainder)
        assertLt(fundManager.totalCommitted(), 1000000); // Less than 1 USDC in wei
    }

    // ============================================
    // 3. Integration with Invoice Lifecycle Tests
    // ============================================

    function testCapitalCall_InvoiceFactoring_RepaymentCycle() public {
        // Setup and capital call
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        vm.prank(capitalCaller);
        fundManager.capitalCall(INVESTOR1_COMMITMENT);
        
        uint256 initialPoolAssets = bullaFactoring.totalAssets();
        
        // Create and fund invoice
        uint256 invoiceAmount = 80_000 * 1e6;
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, 1000, 100, 8000, 0);
        
        vm.prank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        vm.prank(bob);
        uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, 8000, address(0));
        
        // Fast forward and pay invoice
        vm.warp(block.timestamp + 30 days);
        
        vm.prank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        vm.prank(alice);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        
        // Pool should have more assets due to interest earned
        assertGt(bullaFactoring.totalAssets(), initialPoolAssets);
        
        // Investor's shares should be worth more
        uint256 investor1Shares = bullaFactoring.balanceOf(investor1);
        uint256 investor1Assets = bullaFactoring.convertToAssets(investor1Shares);
        assertGt(investor1Assets, INVESTOR1_COMMITMENT);
    }

    function testCapitalCall_MultipleInvoices_PortfolioDiversification() public {
        // Large capital call to support multiple invoices
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        vm.prank(investor2);
        fundManager.commit(INVESTOR2_COMMITMENT);
        
        vm.prank(capitalCaller);
        fundManager.capitalCall(300_000 * 1e6); // Full commitment
        
        // Fund multiple invoices
        uint256[] memory invoiceIds = new uint256[](3);
        uint256[] memory invoiceAmounts = new uint256[](3);
        invoiceAmounts[0] = 50_000 * 1e6;
        invoiceAmounts[1] = 75_000 * 1e6;
        invoiceAmounts[2] = 60_000 * 1e6;
        
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmounts[i], dueBy + (i * 10 days));
            
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], 1000, 100, 8000, 0);
            
            vm.prank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            vm.prank(bob);
            bullaFactoring.fundInvoice(invoiceIds[i], 8000, address(0));
        }
        // Pay invoices at different times to simulate real portfolio
        vm.warp(block.timestamp + 25 days);
        
        vm.prank(alice);
        asset.approve(address(bullaClaim), invoiceAmounts[0]);
        vm.prank(alice);
        bullaClaim.payClaim(invoiceIds[0], invoiceAmounts[0]);
        
        vm.warp(block.timestamp + 20 days);
        
        vm.prank(alice);
        asset.approve(address(bullaClaim), invoiceAmounts[1] + invoiceAmounts[2]);
        vm.prank(alice);
        bullaClaim.payClaim(invoiceIds[1], invoiceAmounts[1]);
        vm.prank(alice);
        bullaClaim.payClaim(invoiceIds[2], invoiceAmounts[2]);
        
        
        
        // Both investors should benefit from diversified portfolio returns
        uint256 investor1Value = bullaFactoring.convertToAssets(bullaFactoring.balanceOf(investor1));
        uint256 investor2Value = bullaFactoring.convertToAssets(bullaFactoring.balanceOf(investor2));
        
        assertGt(investor1Value, INVESTOR1_COMMITMENT);
        assertGt(investor2Value, INVESTOR2_COMMITMENT);
    }

    // ============================================
    // 4. Insolvent Investor Handling Tests
    // ============================================

    function testCapitalCall_InsolventInvestor_AutomaticRemoval() public {
        // Setup commitments
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        vm.prank(investor2);
        fundManager.commit(INVESTOR2_COMMITMENT);
        
        // Make investor2 insolvent by transferring away their USDC
        vm.prank(investor2);
        asset.transfer(address(0xdead), INVESTOR2_COMMITMENT);
        
        // Capital call should handle insolvent investor
        vm.expectEmit(true, true, false, true);
        emit InvestorInsolvent(investor2, 100_000 * 1e6); // Expected amount for 50% call
        
        vm.prank(capitalCaller);
        (uint256 totalCalled, uint256 insolventCount) = fundManager.capitalCall(150_000 * 1e6);
        
        // Only investor1's portion should be called
        assertEq(totalCalled, 50_000 * 1e6); // Only investor1's 50% of 100k
        assertEq(insolventCount, 1);
        
        // Verify only investor1 received shares (investor2 was insolvent)
        assertEq(bullaFactoring.balanceOf(investor1), 50_000 * 1e6);
        assertEq(bullaFactoring.balanceOf(investor2), 0);
        
        // Verify investor2's commitment was reduced to 0 due to insolvency
        (, uint144 commitment2) = fundManager.capitalCommitments(investor2);
        assertEq(uint256(commitment2), 0);
    }

    function testCapitalCall_InsufficientAllowance_TreatedAsInsolvent() public {
        // Setup commitments but insufficient allowance
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        // Reduce investor1's allowance
        vm.prank(investor1);
        asset.approve(address(fundManager), 30_000 * 1e6); // Less than what will be called
        
        vm.expectEmit(true, true, false, true);
        emit InvestorInsolvent(investor1, INVESTOR1_COMMITMENT);
        
        vm.prank(capitalCaller);
        (uint256 totalCalled, uint256 insolventCount) = fundManager.capitalCall(INVESTOR1_COMMITMENT);
        
        assertEq(totalCalled, 0);
        assertEq(insolventCount, 1);
        assertEq(bullaFactoring.balanceOf(investor1), 0);
    }

    // ============================================
    // 5. Permission Integration Tests
    // ============================================

    function testFundManager_RespectsFactoringPoolPermissions() public {
        // Remove fund manager from deposit permissions
        depositPermissions.disallow(address(fundManager));
        
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        // Capital call should fail due to lack of permissions
        vm.prank(capitalCaller);
        vm.expectRevert(abi.encodeWithSelector(BullaFactoringV2_1.UnauthorizedDeposit.selector, address(fundManager))); // Should revert due to unauthorized deposit
        fundManager.capitalCall(INVESTOR1_COMMITMENT);
        
        // Re-enable permissions
        depositPermissions.allow(address(fundManager));
        
        // Now it should work
        vm.prank(capitalCaller);
        (uint256 totalCalled,) = fundManager.capitalCall(INVESTOR1_COMMITMENT);
        
        assertEq(totalCalled, INVESTOR1_COMMITMENT);
    }

    // ============================================
    // 6. Advanced Integration Scenarios
    // ============================================

    function testFundManager_IntegrationWithRedemptions() public {
        // Setup capital and fund factoring pool
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        vm.prank(capitalCaller);
        fundManager.capitalCall(INVESTOR1_COMMITMENT);
        
        // Allow investor to redeem
        redeemPermissions.allow(investor1);
        
        // Verify investor can redeem their shares directly
        uint256 investorShares = bullaFactoring.balanceOf(investor1);
        assertEq(investorShares, INVESTOR1_COMMITMENT);
        
        vm.prank(investor1);
        uint256 redeemedAssets = bullaFactoring.redeem(investorShares, investor1, investor1);
        
        assertEq(redeemedAssets, INVESTOR1_COMMITMENT);
        assertEq(bullaFactoring.balanceOf(investor1), 0);
    }

    // ============================================
    // 7. Edge Cases and Error Conditions
    // ============================================

    function testFundManager_WithoutCommitments_CannotCall() public {
        // No commitments made
        vm.prank(capitalCaller);
        vm.expectRevert(IBullaFactoringFundManager.CallTooHigh.selector);
        fundManager.capitalCall(1000 * 1e6);
    }

    function testCommitmentUpdate_AdjustsTotalCommitted() public {
        // Initial commitment
        vm.prank(investor1);
        fundManager.commit(INVESTOR1_COMMITMENT);
        
        assertEq(fundManager.totalCommitted(), INVESTOR1_COMMITMENT);
        
        // Update commitment to higher amount
        uint256 newCommitment = 150_000 * 1e6;
        asset.mint(investor1, 50_000 * 1e6); // Mint additional funds
        vm.prank(investor1);
        asset.approve(address(fundManager), newCommitment);
        
        vm.prank(investor1);
        fundManager.commit(newCommitment);
        
        assertEq(fundManager.totalCommitted(), newCommitment);
        
        // Update to lower amount
        uint256 reducedCommitment = 80_000 * 1e6;
        vm.prank(investor1);
        fundManager.commit(reducedCommitment);
        
        assertEq(fundManager.totalCommitted(), reducedCommitment);
    }
} 