// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IRedemptionQueue} from "../../contracts/interfaces/IRedemptionQueue.sol";
import {IBullaFactoringV2} from "../../contracts/interfaces/IBullaFactoring.sol";

/**
 * @title TestMissingCoverage
 * @notice Tests for functions that were previously untested or under-tested
 * @dev Covers: decimals(), mint(), getFundInfo(), setRedemptionQueue()
 */
contract TestMissingCoverage is CommonSetup {

    // ============================================
    // 1. Test decimals() Function
    // ============================================

    function testDecimals() public view {
        uint8 expectedDecimals = 6; // MockUSDC has 6 decimals
        assertEq(bullaFactoring.decimals(), expectedDecimals, "Should return 6 decimals matching underlying asset");
    }

    function testDecimalsMatchesAsset() public view {
        // Verify decimals matches the underlying asset
        assertEq(
            bullaFactoring.decimals(),
            asset.decimals(),
            "Factoring decimals should match asset decimals"
        );
    }

    // ============================================
    // 2. Test mint() Function (Should Revert)
    // ============================================

    function testMintReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        bullaFactoring.mint(100000, alice);
    }

    function testMintRevertsForAnyAmount() public {
        // Test with zero
        vm.prank(alice);
        vm.expectRevert();
        bullaFactoring.mint(0, alice);
        
        // Test with large amount
        vm.prank(bob);
        vm.expectRevert();
        bullaFactoring.mint(type(uint256).max, bob);
    }

    function testMintRevertsForAnyUser() public {
        // Test with different users
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = address(this);
        
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            vm.expectRevert();
            bullaFactoring.mint(100, users[i]);
        }
    }

    // ============================================
    // 3. Test getFundInfo() Function
    // ============================================

    function testGetFundInfoInitialState() public view {
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        // Check initial values
        assertGt(bytes(info.name).length, 0, "Fund should have a name");
        assertEq(info.fundBalance, 0, "Initial fundBalance should be 0");
        assertEq(info.deployedCapital, 0, "Initial deployedCapital should be 0");
        assertEq(info.capitalAccount, 0, "Initial capitalAccount should be 0");
        assertEq(info.tokensAvailableForRedemption, 0, "Initial tokensAvailableForRedemption should be 0");
        assertGt(info.creationTimestamp, 0, "Should have a creation timestamp");
        assertEq(info.adminFeeBps, adminFeeBps, "adminFeeBps should match");
        assertEq(info.targetYieldBps, targetYield, "targetYieldBps should match");
    }

    function testGetFundInfoAfterDeposit() public {
        uint256 depositAmount = 100000;
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        assertEq(info.capitalAccount, depositAmount, "capitalAccount should equal deposit");
        assertEq(info.fundBalance, depositAmount, "fundBalance should equal deposit (no deployed capital)");
        assertEq(info.deployedCapital, 0, "deployedCapital should be 0 (no invoices funded)");
        assertGt(info.price, 0, "price should be greater than 0");
        assertGt(info.tokensAvailableForRedemption, 0, "should have tokens available for redemption");
    }

    function testGetFundInfoAfterInvoiceFunding() public {
        // Setup: Deposit and fund an invoice
        uint256 depositAmount = 100000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 50000, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        uint256 fundedAmountNet = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        assertEq(info.deployedCapital, fundedAmountNet, "deployedCapital should equal funded amount net");
        assertLt(info.fundBalance, depositAmount, "fundBalance should be less than initial deposit");
        assertEq(info.capitalAccount, depositAmount, "capitalAccount should still equal total deposit");
        assertGt(info.price, 0, "price should be greater than 0");
    }

    function testGetFundInfoAfterInvoicePayment() public {
        // Setup: Deposit, fund, and pay an invoice
        uint256 depositAmount = 100000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 50000, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        // Pay the invoice - Alice is the debtor and needs funds to pay
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 50000);
        bullaClaim.payClaim(invoiceId, 50000);
        vm.stopPrank();
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        assertEq(info.deployedCapital, 0, "deployedCapital should be 0 after invoice is paid");
        assertGt(info.capitalAccount, depositAmount, "capitalAccount should increase due to interest");
    }

    function testGetFundInfoAfterWithdrawal() public {
        uint256 depositAmount = 100000;
        uint256 withdrawAmount = 30000;
        
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        vm.startPrank(alice);
        bullaFactoring.withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        assertEq(info.capitalAccount, depositAmount - withdrawAmount, "capitalAccount should reflect withdrawal");
        assertEq(info.fundBalance, depositAmount - withdrawAmount, "fundBalance should reflect withdrawal");
        assertEq(info.tokensAvailableForRedemption, depositAmount - withdrawAmount, "tokensAvailableForRedemption should reflect withdrawal");
    }

    function testGetFundInfoWithMultipleInvoices() public {
        // Setup: Deposit
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        uint256 totalFunded = 0;
        
        // Fund multiple invoices
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(bob);
            uint256 invoiceId = createClaim(bob, alice, 30000 + (i * 10000), dueBy);
            
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
            
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            uint256 fundedAmount = bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            totalFunded += fundedAmount;
            vm.stopPrank();
        }
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        assertGt(info.deployedCapital, 0, "Should have deployed capital");
        assertLt(info.fundBalance, depositAmount, "Fund balance should be reduced by deployed capital");
        assertEq(info.capitalAccount, depositAmount, "Capital account should still equal total deposit");
    }

    function testGetFundInfoWithLoanOffer() public {
        // Setup: Deposit
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Create loan offer
        uint256 principalAmount = 50000;
        uint16 targetYieldBps = 730; // 7.3%
        uint16 spreadBpsValue = 100; // 1%
        uint256 termLength = 90 days;
        uint16 numberOfPeriodsPerYear = 365;
        string memory description = "Test loan";
        
        vm.prank(underwriter);
        bullaFactoring.offerLoan(
            alice, // debtor
            targetYieldBps,
            spreadBpsValue,
            principalAmount,
            termLength,
            numberOfPeriodsPerYear,
            description
        );
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        // Loan offers are pending and don't immediately deploy capital until accepted
        // Just verify getFundInfo works correctly
        assertEq(info.capitalAccount, depositAmount, "Capital account should equal deposit");
        assertGt(bytes(info.name).length, 0, "Should have name");
        assertGt(info.price, 0, "Should have price");
    }

    function testGetFundInfoAllFields() public {
        // Comprehensive test setting up various states
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        
        // Fund an invoice
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, 50000, dueBy);
        
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
        
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        // Verify all fields are set correctly
        assertGt(bytes(info.name).length, 0, "name should be set");
        assertGt(info.creationTimestamp, 0, "creationTimestamp should be set");
        assertGt(info.fundBalance, 0, "fundBalance should be set");
        assertGt(info.deployedCapital, 0, "deployedCapital should be set");
        assertGt(info.capitalAccount, 0, "capitalAccount should be set");
        assertGt(info.price, 0, "price should be set");
        assertGt(info.tokensAvailableForRedemption, 0, "tokensAvailableForRedemption should be set");
        assertEq(info.adminFeeBps, adminFeeBps, "adminFeeBps should match");
        assertEq(info.targetYieldBps, targetYield, "targetYieldBps should match");
        
        // Verify relationships between fields
        // Note: fundBalance + deployedCapital might not exactly equal capitalAccount due to withheld fees
        assertApproxEqAbs(
            info.fundBalance + info.deployedCapital,
            info.capitalAccount,
            1000, // Allow 1000 wei difference for fees
            "fundBalance + deployedCapital should approximately equal capitalAccount"
        );
    }

    // ============================================
    // 4. Test setRedemptionQueue() Function
    // ============================================

    function testSetRedemptionQueueOnlyOwner() public {
        // Deploy a new RedemptionQueue for testing
        IRedemptionQueue newQueue = bullaFactoring.getRedemptionQueue(); // Use existing as placeholder
        address newQueueAddress = address(newQueue);
        
        // Should fail for non-owner
        vm.prank(alice);
        vm.expectRevert();
        bullaFactoring.setRedemptionQueue(newQueueAddress);
    }

    function testSetRedemptionQueueSuccess() public {
        // Get current queue
        IRedemptionQueue oldQueue = bullaFactoring.getRedemptionQueue();
        address oldQueueAddress = address(oldQueue);
        
        // For testing, we'll use the same address (in production you'd deploy a new contract)
        address newQueueAddress = oldQueueAddress;
        
        // Should succeed for owner
        vm.prank(bullaFactoring.owner());
        bullaFactoring.setRedemptionQueue(newQueueAddress);
        
        // Verify the change
        assertEq(
            address(bullaFactoring.getRedemptionQueue()),
            newQueueAddress,
            "RedemptionQueue address should be updated"
        );
    }

    function testSetRedemptionQueueWithZeroAddressReverts() public {
        // Setting to zero address should revert
        vm.prank(bullaFactoring.owner());
        vm.expectRevert();
        bullaFactoring.setRedemptionQueue(address(0));
    }

    function testSetRedemptionQueueEmitsEvent() public {
        IRedemptionQueue currentQueue = bullaFactoring.getRedemptionQueue();
        address oldAddress = address(currentQueue);
        address newAddress = address(0x123);
        
        vm.prank(bullaFactoring.owner());
        
        // Expect RedemptionQueueChanged event
        vm.expectEmit(true, true, false, false);
        emit RedemptionQueueChanged(oldAddress, newAddress);
        
        bullaFactoring.setRedemptionQueue(newAddress);
        
        // Verify it worked
        assertEq(address(bullaFactoring.getRedemptionQueue()), newAddress);
    }
    
    event RedemptionQueueChanged(address indexed oldQueue, address indexed newQueue);

    function testSetRedemptionQueueMultipleTimes() public {
        IRedemptionQueue queue = bullaFactoring.getRedemptionQueue();
        address addr1 = address(queue);
        address addr2 = address(0x123);
        address addr3 = address(0x456);
        
        // Set multiple times
        vm.startPrank(bullaFactoring.owner());
        
        bullaFactoring.setRedemptionQueue(addr1);
        assertEq(address(bullaFactoring.getRedemptionQueue()), addr1);
        
        bullaFactoring.setRedemptionQueue(addr2);
        assertEq(address(bullaFactoring.getRedemptionQueue()), addr2);
        
        bullaFactoring.setRedemptionQueue(addr3);
        assertEq(address(bullaFactoring.getRedemptionQueue()), addr3);
        
        vm.stopPrank();
    }

    // ============================================
    // 6. Edge Cases
    // ============================================

    function testGetFundInfoNoDeployedCapital() public view {
        // Test with no activity
        IBullaFactoringV2.FundInfo memory info = bullaFactoring.getFundInfo();
        
        assertEq(info.deployedCapital, 0, "No deployed capital initially");
        assertEq(info.fundBalance, 0, "No fund balance initially");
    }

    function testGetFundInfoConsistency() public {
        // Test that calling getFundInfo multiple times returns consistent data
        vm.prank(alice);
        bullaFactoring.deposit(100000, alice);
        
        IBullaFactoringV2.FundInfo memory info1 = bullaFactoring.getFundInfo();
        IBullaFactoringV2.FundInfo memory info2 = bullaFactoring.getFundInfo();
        
        assertEq(info1.fundBalance, info2.fundBalance, "Consistent fundBalance");
        assertEq(info1.capitalAccount, info2.capitalAccount, "Consistent capitalAccount");
        assertEq(info1.deployedCapital, info2.deployedCapital, "Consistent deployedCapital");
        assertEq(info1.price, info2.price, "Consistent price");
    }
}

