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

    function testFactoringDepositWorkflow() private {
        uint256 invoiceId = 1;
        console.log("Invoice face value 100");
        uint256 faceValue = 100;
        uint256 depositAmount = 10000;

        // Alice deposits 1k USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
        console.log("Alice deposits 1k USDC");

        // Bob deposits 100 ether
        vm.startPrank(bob);
        bullaFactoring.deposit(depositAmount, bob);
        vm.stopPrank();
        console.log("Bob deposits 1k USDC");

        // Log price per share before factoring
        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();
        console.log("Price per share before factoring: ", pricePerShareBefore);

        // Check NAV before factoring
        uint256 navBefore = bullaFactoring.totalAssets();
        console.log("NAV before factoring: ", navBefore);

        // Bob factors an invoice
        console.log("Bob factors a 100 USDC invoice");
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId, faceValue);
        vm.stopPrank();

        // Check NAV after factoring
        uint256 navAfterFactoring = bullaFactoring.totalAssets();
        console.log("NAV after factoring: ", navAfterFactoring);
        assertTrue(navAfterFactoring < navBefore, "NAV should decline after factoring");

        // Log price per share after factoring
        uint256 pricePerShareAfterFactoring = bullaFactoring.pricePerShare();
        console.log("Price per share after factoring: ", pricePerShareAfterFactoring);

        // Bob pays the invoice
        console.log("Bob pays the invoice");
        vm.startPrank(bob);
        bullaFactoring.payInvoice(invoiceId);
        vm.stopPrank();

        // Check NAV after invoice is paid
        uint256 navAfterPayment = bullaFactoring.totalAssets();
        console.log("NAV after invoice is paid: ", navAfterPayment);
        assertTrue(navAfterPayment > navAfterFactoring, "NAV should increase after invoice is paid");

        // Log price per share after invoice payment
        uint256 pricePerShareAfterPayment = bullaFactoring.pricePerShare();
        console.log("Price per share after invoice payment: ", pricePerShareAfterPayment);

    }

    function testFactoringWorkflowWithRedemptions() public {
        // Initial deposit of 2000 USDC
        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();
        console.log("Initial deposit of 2000 USDC by Alice");
        console.log("totalSupply(): ", bullaFactoring.totalSupply());


        // Log price per share after initial deposit
        uint256 pricePerShare = bullaFactoring.pricePerShare();
        console.log("Price per share after initial deposit: ", pricePerShare);
        // log capital account
        uint capitalAccount = bullaFactoring.calculateCapitalAccount();
        console.log("Capital account after initial deposit: ", capitalAccount);
        console.log("totalAssets(): ", bullaFactoring.totalAssets());
        console.log("totalDeposits(): ", bullaFactoring.totalDeposits());
        console.log("totalWithdrawals(): ", bullaFactoring.totalWithdrawals());

        // Bob funds an invoice for 100 USDC
        uint256 invoiceId1 = 1;
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId1, 100);
        vm.stopPrank();
        console.log("Alice funds an invoice for 100 USDC");

        // Partial redemption of 1000 USDC
        vm.startPrank(alice);
        bullaFactoring.redeem(1000, alice, alice);
        vm.stopPrank();
        console.log("Alice redeems 1000 USDC");

        // Log price per share after partial redemption
        pricePerShare = bullaFactoring.pricePerShare();
        console.log("Price per share after partial redemption: ", pricePerShare);
        // log capital account
        capitalAccount = bullaFactoring.calculateCapitalAccount();
        console.log("Capital account after partial redemption: ", capitalAccount);
        console.log("totalSupply(): ", bullaFactoring.totalSupply());
        console.log("totalAssets(): ", bullaFactoring.totalAssets());
        console.log("totalDeposits(): ", bullaFactoring.totalDeposits());
        console.log("totalWithdrawals(): ", bullaFactoring.totalWithdrawals());

        // Bob funds a second invoice for 900 USDC
        uint256 invoiceId2 = 2;
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId2, 900);
        vm.stopPrank();
        console.log("Alice funds a second invoice for 900 USDC");

        // Partial redemption of 100 USDC
        vm.startPrank(alice);
        bullaFactoring.redeem(100, alice, alice);
        vm.stopPrank();
        console.log("Alice redeems 100 USDC");

        // Log price per share after second partial redemption
        pricePerShare = bullaFactoring.pricePerShare();
        console.log("Price per share after second partial redemption: ", pricePerShare);
        // log capital account
        capitalAccount = bullaFactoring.calculateCapitalAccount();
        console.log("Capital account after second partial redemption: ", capitalAccount);
        console.log("totalAssets(): ", bullaFactoring.totalAssets());
        console.log("totalDeposits(): ", bullaFactoring.totalDeposits());
        console.log("totalWithdrawals(): ", bullaFactoring.totalWithdrawals());

        // First invoice gets paid back for 100 USDC
        vm.startPrank(bob);
        bullaFactoring.payInvoice(invoiceId1);
        vm.stopPrank();
        console.log("First invoice gets paid back for 100 USDC");

        // Log price per share after first invoice payment
        pricePerShare = bullaFactoring.pricePerShare();
        console.log("Price per share after first invoice payment: ", pricePerShare);
        // log capital account
        capitalAccount = bullaFactoring.calculateCapitalAccount();
        console.log("Capital account after first invoice payment: ", capitalAccount);
        console.log("totalAssets(): ", bullaFactoring.totalAssets());
        console.log("totalDeposits(): ", bullaFactoring.totalDeposits());
        console.log("totalWithdrawals(): ", bullaFactoring.totalWithdrawals());

        // Second invoice gets paid back for 900 USDC
        vm.startPrank(bob);
        bullaFactoring.payInvoice(invoiceId2);
        vm.stopPrank();
        console.log("Second invoice gets paid back for 900 USDC");

        // Log price per share after second invoice payment
        pricePerShare = bullaFactoring.pricePerShare();
        console.log("Price per share after second invoice payment: ", pricePerShare);
        // log capital account
        capitalAccount = bullaFactoring.calculateCapitalAccount();
        console.log("Capital account after second invoice payment: ", capitalAccount);
        console.log("totalAssets(): ", bullaFactoring.totalAssets());
        console.log("totalDeposits(): ", bullaFactoring.totalDeposits());
        console.log("totalWithdrawals(): ", bullaFactoring.totalWithdrawals());
    }

}