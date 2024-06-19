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


contract TestInvoiceUnfactoring is CommonSetup {
    function testUnfactorInvoice() public {
        // Alice deposits into the fund
        uint256 initialDeposit = 1000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDeposit);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        uint invoiceIdAmount = 100;
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Bob unfactors the invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId);
        vm.stopPrank();

        // Assert the invoice NFT is transferred back to Bob and that fund has received the funded amount back
        assertEq(bullaClaimERC721.ownerOf(invoiceId), bob, "Invoice NFT should be returned to Bob");
        assertEq(asset.balanceOf(address(bullaFactoring)), initialDeposit, "Funded amount should be refunded to BullaFactoring");
    }

    function testUnfactorImpairedInvoiceAffectsSharePrice() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 100;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // alice pays both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId03Amount = 50;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();
        uint sharePriceBeforeUnfactoring = bullaFactoring.pricePerShare();

        // Bob unfactors the invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId03);
        vm.stopPrank();
  
        bullaFactoring.reconcileActivePaidInvoices();

        uint256 sharePriceAfterUnfactoring = bullaFactoring.pricePerShare();

        assertTrue(sharePriceAfterUnfactoring > sharePriceBeforeUnfactoring, "Price per share should increase due to unfactored impaired invoice");
        assertEq(bullaFactoring.balanceOf(alice), bullaFactoring.maxRedeem(), "Alice balance should be equal to maxRedeem");

        uint amountToRedeem = bullaFactoring.maxRedeem();

        // Alice redeems all her shares
        vm.prank(alice);
        bullaFactoring.redeem(amountToRedeem, alice, alice);
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();
    }

    function testInterestAccruedOnUnfactoredInvoice() public {
        interestApr = 2000;
        upfrontBps = 8000;
        uint invoiceAmount = 100;

        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 invoiceId01 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        uint balanceBeforeUnfactoring = asset.balanceOf(bob);

        // Bob unfactors the first invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId01);
        vm.stopPrank();

        uint balanceAfterUnfactoring = asset.balanceOf(bob);
        uint refundedAmount = balanceBeforeUnfactoring - balanceAfterUnfactoring;

        vm.startPrank(bob);
        uint256 invoiceId03 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 90 days 
        vm.warp(block.timestamp + 90 days);

        uint balanceBeforeDelayedUnfactoring = asset.balanceOf(bob);

        // Bob unfactors the second invoice
        vm.startPrank(bob);
        bullaFactoring.unfactorInvoice(invoiceId03);
        vm.stopPrank();
  
        uint balanceAfterDelayedUnfactoring = asset.balanceOf(bob);
        uint refundeDelayedUnfactoring = balanceBeforeDelayedUnfactoring - balanceAfterDelayedUnfactoring;

        // If the unfactoring is delayed, the will be more interest to be paid BY Bob, therefore, his refund payment should be bigger than the low interest unfactor.
        assertTrue(refundedAmount < refundeDelayedUnfactoring, "Interest should accrue when unfactoring invoices");
    } 
}