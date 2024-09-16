// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoring } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimInvoiceProviderAdapter } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import { DAOMock } from 'contracts/mocks/DAOMock.sol';
import { TestSafe } from 'contracts/mocks/gnosisSafe.sol';
import "@bulla-network/contracts/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";

import { CommonSetup } from './CommonSetup.t.sol';


contract TestFeesAndTax is CommonSetup {
    function testWithdrawFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.01 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Check initial balances
        uint256 initialBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 initialOwnerBalance = asset.balanceOf(address(this));



        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        // Check final balances
        uint256 finalBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 finalOwnerBalance = asset.balanceOf(address(this));

        // Check that the Bulla DAO and the owner's balances have increased by the expected fee amounts
        assertTrue(finalBullaDaoBalance > initialBullaDaoBalance, "Bulla DAO should receive protocol fees");
        assertTrue(finalOwnerBalance > initialOwnerBalance, "Owner should receive admin fees");
    }

    function testFeesDeductionFromCapitalAccount() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 90000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // owner will reconcile paid invoices to account for any realized gains or losses, and fees
        bullaFactoring.reconcileActivePaidInvoices();

        uint capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        uint capitalAccountAfter = bullaFactoring.calculateCapitalAccount();

        assertEq(capitalAccountAfter, capitalAccountBefore, "Capital Account should remain unchanged");
    }

    function testTaxAccrualAndWithdraw() public {
        dueBy = block.timestamp + 60 days; 
        uint256 invoiceAmount = 1000000000; 
        interestApr = 1000; 
        upfrontBps = 8000; 

        uint256 initialDeposit = 20 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();


        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 60;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint taxAmountBefore = bullaFactoring.taxBalance();
    
        assertTrue(taxAmountBefore > 0, "Tax accrues on invoice payment");

        // Retrieve the tax amount paid for the specific invoice
        uint256 expectedTaxAmount = bullaFactoring.paidInvoiceTax(invoiceId);
        assertEq(taxAmountBefore, expectedTaxAmount, "Tax amount matches the expected value");

        // owner withdraws tax
        bullaFactoring.withdrawTaxBalance();
        uint taxAmountAfter = bullaFactoring.taxBalance();

        assertEq(taxAmountAfter, 0, "Tax balance should be 0 after withdrawal");

        // cannot call when tax balance is 0
        vm.expectRevert(abi.encodeWithSignature("NoTaxBalanceToWithdraw()"));
        bullaFactoring.withdrawTaxBalance();
    }

    function testPoolFeesRemainSameRegardlessOfUpfrontBps() public {
        uint256 initialDeposit = 1000000000000000; // 1,000,000 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000000000; // 100,000 USDC
        uint256 dueDate = block.timestamp + 30 days;

        // Create and fund first invoice with 100% upfront
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, 10000, minDays); // 100% upfront
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId1);
        (, uint256 adminFee1, uint256 targetInterest1, uint256 targetProtocolFee1,) = bullaFactoring.calculateTargetFees(invoiceId1, 10000);
        bullaFactoring.fundInvoice(invoiceId1, 10000);
        vm.stopPrank();

        // Create and fund second invoice with 50% upfront
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, 5000, minDays); // 50% upfront
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId2);
        (, uint256 adminFee2, uint256 targetInterest2, uint256 targetProtocolFee2,) = bullaFactoring.calculateTargetFees(invoiceId2, 5000);
        bullaFactoring.fundInvoice(invoiceId2, 5000);
        vm.stopPrank();

        uint capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Assert that target interest and protocol fees are the same for both invoices
        assertEq(targetInterest1, targetInterest2, "Target interest should be the same regardless of upfront percentage");
        assertEq(targetProtocolFee1, targetProtocolFee2, "Target protocol fee should be the same regardless of upfront percentage");
        assertEq(adminFee1, adminFee2, "Admin fee should be the same");

        // Simulate invoices being paid on time
        vm.warp(dueDate - 1);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId1, invoiceAmount);
        bullaClaim.payClaim(invoiceId2, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint256 availableAssetsAfter = bullaFactoring.totalAssets();
        uint256 totalAssetsAfter = asset.balanceOf(address(bullaFactoring));

        // Calculate realized fees
        uint realizedFees = totalAssetsAfter - availableAssetsAfter;

        // Calculate expected fees
        uint256 expectedFees = (adminFee1 + targetInterest1 + targetProtocolFee1) + (adminFee2 + targetInterest2 + targetProtocolFee2);

        uint gainLoss = bullaFactoring.calculateCapitalAccount() - capitalAccountBefore;
        // Assert that realized fees match expected fees
        assertEq(realizedFees + gainLoss, expectedFees, "Realized fees + realized gains should match expected fees for both invoices");
    }

    function testAdminFeeAccruesOvertime() public {
        uint256 initialDeposit = 1000000000000000; // 1,000,000 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000000000; // 100,000 USDC
        uint256 dueDate = block.timestamp + 30 days;

        // Create and fund first invoice
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, 10000, minDays); // 100% upfront
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId1);
        (, uint256 targetAdminFee1,,,) = bullaFactoring.calculateTargetFees(invoiceId1, 10000);
        bullaFactoring.fundInvoice(invoiceId1, 10000);
        vm.stopPrank();


        // Simulate first invoice being paid after 15 days
        vm.warp(dueDate - 14 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        (,,,uint trueAdminFee1) = bullaFactoring.calculateKickbackAmount(invoiceId1);
        bullaClaim.payClaim(invoiceId1, invoiceAmount);
        vm.stopPrank();

        dueDate = block.timestamp + 30 days;

                // Create and fund second invoice
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, 10000, minDays);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId2);
        (, uint256 targetAdminFee2,,, ) = bullaFactoring.calculateTargetFees(invoiceId2, 10000);
        bullaFactoring.fundInvoice(invoiceId2, 10000);
        vm.stopPrank();

        assertEq(targetAdminFee2, targetAdminFee1, "Admin fee should be the same");

        // Simulate first invoice being paid after 30 days
        vm.warp(dueDate - 1 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        (,,,uint trueAdminFee2) = bullaFactoring.calculateKickbackAmount(invoiceId1);

        assertGt(trueAdminFee2, trueAdminFee1, "Admin fee should increase overtime");
    }

    function testSetBullaDao() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.01 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Check initial balances
        uint256 initialAliceBalance = asset.balanceOf(alice);

        bullaFactoring.reconcileActivePaidInvoices();

        // Change bulla dao address to Alice
        vm.startPrank(address(this));
        bullaFactoring.setBullaDaoAddress(alice);
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(alice);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        // Check final balances
        uint256 finalAliceBalance = asset.balanceOf(alice);

        // Check that the new Bulla DAO balance has increased by the expected fee amounts
        assertTrue(finalAliceBalance > initialAliceBalance, "Bulla DAO should receive protocol fees");
    }

    function testSetProtocolFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set protocol fee to 0
        vm.startPrank(address(this)); 
        bullaFactoring.setProtocolFeeBps(0);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        vm.expectRevert(abi.encodeWithSignature("NoFeesToWithdraw()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

    }

    function testSetAdminFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set admin fee to 0
        vm.startPrank(address(this)); 
        bullaFactoring.setAdminFeeBps(0);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Withdraw admin fees but aren't none since fee = 0
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSignature("NoFeesToWithdraw()"));
        bullaFactoring.withdrawAdminFees();
        vm.stopPrank();
    }

    function testSetTaxBalance() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set tax bps to 0
        vm.startPrank(address(this)); 
        bullaFactoring.setTaxBps(0);
        vm.stopPrank();

        // Simulate funding an invoice to generate taxes
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Withdraw tax but aren't none since taxBps = 0
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSignature("NoTaxBalanceToWithdraw()"));
        bullaFactoring.withdrawTaxBalance();
        vm.stopPrank();
    }

    function testSetTargetYield() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set target yield to 0
        vm.startPrank(address(this)); 
        bullaFactoring.setTargetYield(0);
        vm.stopPrank();

        uint pricePerShareBefore = bullaFactoring.pricePerShare();

        // Simulate funding an invoice to generate taxes
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, bullaFactoring.targetYieldBps(), upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfter = bullaFactoring.pricePerShare();

        assertEq(pricePerShareAfter, pricePerShareBefore, "Price per share should be the same if pnl = 0");

        assertEq(bullaFactoring.balanceOf(alice), bullaFactoring.maxRedeem(), "Alice balance should be equal to maxRedeem");

        uint amountToRedeem = bullaFactoring.maxRedeem();

        // Alice redeems all her shares
        vm.prank(alice);
        bullaFactoring.redeem(amountToRedeem, alice, alice);
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();

    }

    function testTaxRateIsAccurate() public {
        uint256 initialDeposit = 10 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set tax to 100%
        vm.startPrank(address(this)); 
        bullaFactoring.setTaxBps(10_000);
        vm.stopPrank();

        // if tax is 100%, there should be no profit from this
        uint capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // Simulate funding an invoice to generate taxes
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // if tax is 100%, there should be no profit from this
        uint capitalAccountAfter = bullaFactoring.calculateCapitalAccount();

        assertEq(capitalAccountAfter, capitalAccountBefore, "Profitless invoice should have not changed capital account");
        vm.stopPrank();

    }
}
