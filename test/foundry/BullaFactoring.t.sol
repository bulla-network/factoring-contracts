// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { MockUSDC } from 'contracts/mocks/mockUSDC.sol';

contract TestBullaFactoring is Test {

    BullaFactoring public bullaFactoring;
    MockUSDC public asset;

    address alice = address(0xA11c3);
    address bob = address(0xb0b);

    function setUp() public {
        asset = new MockUSDC();
        bullaFactoring = new BullaFactoring(asset);

        asset.mint(alice, 1000 ether);
        asset.mint(bob, 1000 ether);

        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();
    }

    function calculateFundedAmount(uint256 faceValue, uint256 fundingPercentage) internal pure returns (uint256) {
        return (faceValue * fundingPercentage) / 10000;
    }
    
    function calculatePricePerShare(uint256 capitalAccount, uint256 sharesOutstanding, uint SCALING_FACTOR) public pure returns (uint256) {
        if (sharesOutstanding == 0) return 0;
        return (capitalAccount * SCALING_FACTOR) / sharesOutstanding;
    }

    function testDepositAndRedemption() public {
        uint256 dueDate = block.timestamp + 30 days;

        // Initial deposit of 2000 USDC
        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();
        
        assertEq(bullaFactoring.totalSupply(), initialDeposit, "Initial total supply should equal initial deposit");

        uint256 pricePerShare = bullaFactoring.pricePerShare();
        uint capitalAccount = bullaFactoring.calculateCapitalAccount();
        uint sharePriceCheck = calculatePricePerShare(capitalAccount, bullaFactoring.totalSupply(), bullaFactoring.SCALING_FACTOR());
        assertEq(pricePerShare, sharePriceCheck);
        assertEq(capitalAccount, initialDeposit, "Initial capital account should equal initial deposit");
        assertEq(bullaFactoring.totalAssets(), initialDeposit, "Initial capital account should equal initial deposit");

        // Bob funds an invoice for 100 USDC
        uint256 invoiceId1 = 1;
        vm.startPrank(bob);
        uint firstInvoiceAmount = 100;
        uint firstFundedAmount = calculateFundedAmount(firstInvoiceAmount, bullaFactoring.fundingPercentage());
        bullaFactoring.fundInvoice(invoiceId1, firstInvoiceAmount, dueDate);
        vm.stopPrank();

        // Partial redemption of 1000 USDC
        vm.startPrank(alice);
        uint firstRedemption = 1000;
        bullaFactoring.redeem(firstRedemption, alice, alice);
        vm.stopPrank();

        pricePerShare = bullaFactoring.pricePerShare();
        capitalAccount = bullaFactoring.calculateCapitalAccount();
        sharePriceCheck = calculatePricePerShare(capitalAccount, bullaFactoring.totalSupply(), bullaFactoring.SCALING_FACTOR());
        assertEq(pricePerShare, sharePriceCheck);
        assertEq(capitalAccount, initialDeposit - firstRedemption, "Capital account should be the differentce between initial deposit and what has been redeemed so far");
        assertEq(bullaFactoring.totalSupply(), initialDeposit - firstRedemption);
        uint expectedTotalAssets = initialDeposit - firstRedemption - firstFundedAmount;
        assertEq(bullaFactoring.totalAssets(), initialDeposit - firstRedemption - firstFundedAmount, "Total assets should reflect the amount of stables in the vault");

        // Bob funds a second invoice for 900 USDC
        uint256 invoiceId2 = 2;
        vm.startPrank(bob);
        uint secondInvoiceAmount = 900;
        bullaFactoring.fundInvoice(invoiceId2, secondInvoiceAmount, dueDate);
        uint secondFundedAmount = calculateFundedAmount(secondInvoiceAmount, bullaFactoring.fundingPercentage());
        vm.stopPrank();

        // Partial redemption of 100 USDC
        vm.startPrank(alice);
        uint secondRedemption = 100;
        bullaFactoring.redeem(secondRedemption, alice, alice);
        vm.stopPrank();

        pricePerShare = bullaFactoring.pricePerShare();
        capitalAccount = bullaFactoring.calculateCapitalAccount();
        sharePriceCheck = calculatePricePerShare(capitalAccount, bullaFactoring.totalSupply(), bullaFactoring.SCALING_FACTOR());
        assertEq(pricePerShare, sharePriceCheck);
        assertEq(capitalAccount, initialDeposit - firstRedemption - secondRedemption, "Capital account should be the differentce between initial deposit and what has been redeemed so far");
        assertEq(bullaFactoring.totalSupply(), initialDeposit - firstRedemption - secondRedemption);
        expectedTotalAssets = initialDeposit - firstRedemption - secondRedemption - firstFundedAmount - secondFundedAmount;
        assertEq(bullaFactoring.totalAssets(), expectedTotalAssets, "Total assets should reflect the amount of stables in the vault");
    }

    function testPricePerToken() public {
        uint256 dueDate = block.timestamp + 30 days;

        uint256 initialDeposit = 900;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceId1 = 1;
        vm.startPrank(bob);
        uint firstInvoiceAmount = 100;
        bullaFactoring.fundInvoice(invoiceId1, firstInvoiceAmount, dueDate);
        vm.stopPrank();

        uint256 invoiceId2 = 2;
        vm.startPrank(bob);
        uint secondInvoiceAmount = 900;
        bullaFactoring.fundInvoice(invoiceId2, secondInvoiceAmount, dueDate);
        vm.stopPrank();

        // First invoice gets paid back for 100 USDC
        vm.startPrank(bob);
        bullaFactoring.payInvoice(invoiceId1);
        vm.stopPrank();

        // Second invoice gets paid back for 900 USDC
        vm.startPrank(bob);
        bullaFactoring.payInvoice(invoiceId2);
        vm.stopPrank();

        uint pricePerShare = bullaFactoring.pricePerShare();
        uint capitalAccount = bullaFactoring.calculateCapitalAccount();
        uint sharePriceCheck = calculatePricePerShare(capitalAccount, bullaFactoring.totalSupply(), bullaFactoring.SCALING_FACTOR());
        assertEq(pricePerShare, sharePriceCheck);
    }
}