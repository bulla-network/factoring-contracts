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
import "@bulla-network/contracts/interfaces/IBullaClaim.sol";
import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";

import { CommonSetup } from './CommonSetup.t.sol';


contract TestPricePerShareCalculations is CommonSetup {
    function testPriceUpdateInvoicesRedeemed() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialFactorerBalance = asset.balanceOf(bob);

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
        uint invoiceId02Amount = 900000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        uint factorerBalanceAfterFactoring = asset.balanceOf(bob);

        assertEq(factorerBalanceAfterFactoring, initialFactorerBalance + bullaFactoring.getFundedAmount(invoiceId01) + bullaFactoring.getFundedAmount(invoiceId02));

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // automation will signal that we have some paid invoices
        (uint256[] memory paidInvoices, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoices.length, 2);

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();
        // owner will reconcile paid invoices to account for any realized gains or losses
        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();
        uint capitalAccount = bullaFactoring.calculateCapitalAccount();
        uint sharePriceCheck = calculatePricePerShare(capitalAccount, bullaFactoring.totalSupply(), bullaFactoring.SCALING_FACTOR());
        assertEq(pricePerShareAfterReconciliation, sharePriceCheck);

        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should increased due to redeemed invoices");
    }

    function testPriceUpdateInvoicesImpaired() public {
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

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId03Amount = 10;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps);
        vm.stopPrank();

        // we reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();
        uint pricePerShareBeforeImpairment = bullaFactoring.pricePerShare();

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        (, uint256[] memory impairedInvoices) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoices.length, 1);

        // Check the impact on the price per share due to the impaired invoice
        bullaFactoring.reconcileActivePaidInvoices();
        uint pricePerShareAfterImpairment = bullaFactoring.pricePerShare();
        assertTrue(pricePerShareAfterImpairment < pricePerShareBeforeImpairment, "Price per share should decrease due to impaired invoice");
    }
    
    function testReducedPricePerShareDueToImpairment() public {
        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Bob creates and funds an invoice
        vm.startPrank(bob);
        uint invoiceIdAmount = 300; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        uint initialPricePerShare = bullaFactoring.pricePerShare();

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        // automation will signal that we have an impaired invoice
        (, uint256[] memory impairedInvoices) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoices.length, 1);


        bullaFactoring.reconcileActivePaidInvoices(); 

        uint pricePerShareAfter = bullaFactoring.pricePerShare();
        assertLt(pricePerShareAfter, initialPricePerShare, "Price per share should decline due to impairment");
    }

}