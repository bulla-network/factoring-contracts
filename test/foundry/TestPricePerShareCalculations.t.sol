// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimInvoiceProviderAdapterV2 } from 'contracts/BullaClaimInvoiceProviderAdapter.sol';
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


contract TestPricePerShareCalculations is CommonSetup {
    function testPriceUpdateInvoicesRedeemed() public {
        interestApr = 1000;
        upfrontBps = 8000;

        uint256 initialDeposit = 9000000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
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

        uint pricePerShareBeforeReconciliation = bullaFactoring.pricePerShare();

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

        // owner will reconcile paid invoices to account for any realized gains or losses
        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareAfterReconciliation = bullaFactoring.pricePerShare();

        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should increased due to redeemed invoices");
    }

    function testPriceUpdateInvoicesImpaired() public {
        uint256 initialDeposit = 2000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
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
        vault.deposit(initialDeposit, alice);
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

    function testPriceDoesntChangeAfterSecondFactoring() public {
        uint256 initialDeposit = 100000000000;
        vm.startPrank(alice);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 1000000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        uint pricePerShareBeforeSecondFactoring = bullaFactoring.pricePerShare();

        vm.startPrank(bob);
        uint invoiceId02Amount = 2000000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        vm.startPrank(alice);
        vault.redeem(initialDeposit / 2, alice, alice);
        vm.stopPrank();

        uint pricePerShareAfterSecondFactoring = bullaFactoring.pricePerShare();

        assertEq(pricePerShareBeforeSecondFactoring, pricePerShareAfterSecondFactoring, "Price per share should not change after second factoring");
    }

    function testConstantSharePrice() public {
        interestApr = 2000;
        upfrontBps = 8000;

        uint256 initialDeposit = 3000000; // deposit 3 USDC
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        vault.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint initialPps = bullaFactoring.pricePerShare();

        vm.startPrank(bob);
        uint invoiceId01Amount = 500000; // 0.5 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays first invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();
        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();

        uint ppsAfterFirstRepayment = bullaFactoring.pricePerShare();

        assertGt(ppsAfterFirstRepayment, initialPps, "Price per share should increase after first repayment");

        // alice deposits an additional 1 USDC
        uint256 anotherDeposit = 1000000; // deposit 1 USDC
        vm.startPrank(alice);
        vault.deposit(anotherDeposit, alice);
        vm.stopPrank();

        uint ppsAfterSecondDeposit = bullaFactoring.pricePerShare();

        assertEq(ppsAfterSecondDeposit, ppsAfterFirstRepayment, "Price per share should remain the same after second deposit");

        vm.startPrank(bob);
        uint invoiceId02Amount = 1000000; // 1 USDC
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps);
        vm.stopPrank();

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays second invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();

        uint ppsAfterSecondRepayment = bullaFactoring.pricePerShare();
        assertGt(ppsAfterSecondRepayment, ppsAfterFirstRepayment, "Price per share should increase after second repayment");

        // alice redeems half of her balance 
        uint256 sharesToWithdraw = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.redeem(sharesToWithdraw, alice, alice);
        vm.stopPrank();

        uint ppsAfterRedemption = bullaFactoring.pricePerShare();

        assertEq(ppsAfterSecondRepayment, ppsAfterRedemption, "Price per share should remain the same after partial redemption");
    }
}

