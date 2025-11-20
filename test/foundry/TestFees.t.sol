// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimV2InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol';
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


contract TestFees is CommonSetup {
    event BullaDaoAddressChanged(address indexed oldAddress, address indexed newAddress);
    event ProtocolFeeBpsChanged(uint16 oldProtocolFeeBps, uint16 newProtocolFeeBps);
    event TargetYieldChanged(uint16 newTargetYield);
    event AdminFeeBpsChanged(uint16 indexed oldFeeBps, uint16 indexed newFeeBps);

    function testWithdrawFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.01 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Check initial balances
        uint256 initialBullaDaoBalance = asset.balanceOf(bullaDao);
        uint256 initialOwnerBalance = asset.balanceOf(address(this));

        vm.warp(block.timestamp + 30 days);

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFeesAndSpreadGains();
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
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 90000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
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

        uint capitalAccountBefore = vault.calculateCapitalAccount();

        // Withdraw admin fees
        vm.startPrank(address(this)); 
        bullaFactoring.withdrawAdminFeesAndSpreadGains();
        vm.stopPrank();

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

        uint capitalAccountAfter = vault.calculateCapitalAccount();

        assertEq(capitalAccountAfter, capitalAccountBefore, "Capital Account should remain unchanged");
    }

    function testPoolFeesRemainSameRegardlessOfUpfrontBps() public {
        uint256 initialDeposit = 1000000000000000; // 1,000,000 USDC
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000000000; // 100,000 USDC
        uint256 dueDate = block.timestamp + 30 days;

        // Create and fund first invoice with 100% upfront
        vm.prank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, 10000, 0); // 100% upfront
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        (, uint256 adminFee1, uint256 targetInterest1, uint256 targetSpread1, uint256 targetProtocolFee1, ) = bullaFactoring.calculateTargetFees(invoiceId1, 10000);
        bullaFactoring.fundInvoice(invoiceId1, 10000, address(0));
        vm.stopPrank();

        // Create and fund second invoice with 50% upfront
        vm.prank(bob);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, 10000, 0); // Approve with 100% max but fund with 50%
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        (, uint256 adminFee2, uint256 targetInterest2, uint256 targetSpread2, uint256 targetProtocolFee2, ) = bullaFactoring.calculateTargetFees(invoiceId2, 5000);
        bullaFactoring.fundInvoice(invoiceId2, 5000, address(0));
        vm.stopPrank();

        uint capitalAccountBefore = vault.calculateCapitalAccount();

        // Assert that target interest and protocol fees are the same for both invoices
        assertEq(targetInterest1, targetInterest2, "Target interest should be the same regardless of upfront percentage");
        assertEq(targetProtocolFee1, targetProtocolFee2, "Target protocol fee should be the same regardless of upfront percentage");
        assertEq(adminFee1, adminFee2, "Admin fee should be the same");
        assertEq(targetSpread1, targetSpread2, "Target spread should be the same regardless of upfront percentage");

        // Simulate invoices being paid on time
        vm.warp(dueDate);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId1, invoiceAmount);
        bullaClaim.payClaim(invoiceId2, invoiceAmount);
        vm.stopPrank();

        uint256 availableAssetsAfter = vault.totalAssets();
        uint256 totalAssetsAfter = asset.balanceOf(address(bullaFactoring));

        // Calculate realized fees
        uint realizedFees = totalAssetsAfter - availableAssetsAfter;

        // Calculate expected fees (protocol fees are now taken upfront at funding time, so excluded here)
        uint256 expectedFees = (adminFee1 + targetInterest1 + targetSpread1 + targetProtocolFee1) + (adminFee2 + targetInterest2 + targetSpread2 + targetProtocolFee2);

        uint gainLoss = vault.calculateCapitalAccount() - capitalAccountBefore;
        // Assert that realized fees match expected fees
        assertEq(realizedFees + gainLoss, expectedFees, "Realized fees + realized gains should match expected fees for both invoices");
    }

    function testAdminFeeAccruesOvertime() public {
        uint256 initialDeposit = 1000000000000000; // 1,000,000 USDC
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 invoiceAmount = 100000000000; // 100,000 USDC
        uint256 dueDate = block.timestamp + 30 days;
        uint256 dueDate2 = block.timestamp + 60 days;

        // Create and fund first invoice
        vm.prank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, 0); // 100% upfront
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId1);
        (, uint256 targetAdminFee1, , , , ) = bullaFactoring.calculateTargetFees(invoiceId1, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId1, upfrontBps, address(0));
        vm.stopPrank();


        // Simulate first invoice being paid after 15 days
        vm.warp(dueDate - 14 days);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        (,,,uint trueAdminFee1) = bullaFactoring.calculateKickbackAmount(invoiceId1);
        vm.stopPrank();

        vm.warp(dueDate);

        // Create and fund second invoice
        vm.prank(bob);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueDate2);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId2);
        (, uint256 targetAdminFee2, , , , ) = bullaFactoring.calculateTargetFees(invoiceId2, upfrontBps);
        bullaFactoring.fundInvoice(invoiceId2, upfrontBps, address(0));
        vm.stopPrank();

        assertEq(targetAdminFee2, targetAdminFee1, "Admin fee should be the same");

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        (,,,uint trueAdminFee2) = bullaFactoring.calculateKickbackAmount(invoiceId1);

        assertGt(trueAdminFee2, trueAdminFee1, "Admin fee should increase overtime");
    }

    function testSetBullaDao() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.01 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Check initial balances
        uint256 initialAliceBalance = asset.balanceOf(alice);

        

        // Change bulla dao address to Alice
        vm.startPrank(bullaDao);
        vm.expectEmit(true, true, true, true);
        emit BullaDaoAddressChanged(bullaDao, alice);
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
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set protocol fee to 0
        vm.startPrank(address(this)); 
        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeBpsChanged(protocolFeeBps, 0);
        bullaFactoring.setProtocolFeeBps(0);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        

        // Withdraw protocol fees
        vm.startPrank(bullaDao);
        vm.expectRevert(abi.encodeWithSignature("NoFeesToWithdraw()"));
        bullaFactoring.withdrawProtocolFees();
        vm.stopPrank();

    }

    function testSetAdminFees() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set admin fee to 0
        vm.startPrank(address(this)); 
        uint16 oldAdminFeeBps = bullaFactoring.adminFeeBps();
        vm.expectEmit(true, true, true, true);
        emit AdminFeeBpsChanged(oldAdminFeeBps, 0);
        bullaFactoring.setAdminFeeBps(0);
        vm.stopPrank();

        // Simulate funding an invoice to generate fees
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        uint16 zeroSpreadBps = 0;
        bullaFactoring.approveInvoice(invoiceId, interestApr, zeroSpreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        

        // Withdraw admin fees but aren't none since fee = 0
        vm.startPrank(address(this));
        vm.expectRevert(abi.encodeWithSignature("NoFeesToWithdraw()"));
        bullaFactoring.withdrawAdminFeesAndSpreadGains();
        vm.stopPrank();
    }

    function testSetTargetYield() public {
        uint256 initialDeposit = 1 ether;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Set target yield to 0
        vm.startPrank(address(this)); 
        vm.expectEmit(true, true, true, true);
        emit TargetYieldChanged(0);
        bullaFactoring.setTargetYield(0);
        vm.stopPrank();

        uint pricePerShareBefore = vault.pricePerShare();

        // Simulate funding an invoice
        vm.startPrank(bob);
        uint256 invoiceAmount = 0.5 ether;
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, bullaFactoring.targetYieldBps(), spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // alice pays invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        

        uint pricePerShareAfter = vault.pricePerShare();

        assertEq(pricePerShareAfter, pricePerShareBefore, "Price per share should be the same if pnl = 0");

        assertEq(vault.balanceOf(alice), vault.maxRedeem(), "Alice balance should be equal to maxRedeem");

        uint amountToRedeem = vault.maxRedeem();

        // Alice redeems all her shares
        vm.prank(alice);
        vault.redeem(amountToRedeem, alice, alice);
        assertEq(vault.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();

    }
}
