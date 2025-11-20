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
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 900000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        vm.stopPrank();

        uint factorerBalanceAfterFactoring = asset.balanceOf(bob);

        (, , , , , , , uint256 fundedAmountNet01, , , , , , ) = bullaFactoring.approvedInvoices(invoiceId01);
        (, , , , , , , uint256 fundedAmountNet02, , , , , , ) = bullaFactoring.approvedInvoices(invoiceId02);
        assertEq(factorerBalanceAfterFactoring, initialFactorerBalance + fundedAmountNet01 + fundedAmountNet02);

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        uint pricePerShareBeforeReconciliation = vault.pricePerShare();

        // alice pays both invoices
        vm.startPrank(alice);
        // bullaClaim is the contract executing the transferFrom method when paying, so it needs to be approved
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        uint pricePerShareAfterReconciliation = vault.pricePerShare();

        assertTrue(pricePerShareBeforeReconciliation < pricePerShareAfterReconciliation, "Price per share should increased due to redeemed invoices");
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
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();

        

        uint pricePerShareBeforeSecondFactoring = vault.pricePerShare();

        vm.startPrank(bob);
        uint invoiceId02Amount = 2000000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(alice);
        vault.redeem(initialDeposit / 2, alice, alice);
        vm.stopPrank();

        uint pricePerShareAfterSecondFactoring = vault.pricePerShare();

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

        uint initialPps = vault.pricePerShare();

        vm.startPrank(bob);
        uint invoiceId01Amount = 500000; // 0.5 USDC
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 30 days);

        // alice pays first invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        vm.stopPrank();
      
        uint ppsAfterFirstRepayment = vault.pricePerShare();

        assertGt(ppsAfterFirstRepayment, initialPps, "Price per share should increase after first repayment");

        // alice deposits an additional 1 USDC
        uint256 anotherDeposit = 1000000; // deposit 1 USDC
        vm.startPrank(alice);
        vault.deposit(anotherDeposit, alice);
        vm.stopPrank();

        uint ppsAfterSecondDeposit = vault.pricePerShare();

        assertEq(ppsAfterSecondDeposit, ppsAfterFirstRepayment, "Price per share should remain the same after second deposit");

        vm.startPrank(bob);
        uint invoiceId02Amount = 1000000; // 1 USDC
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        bullaFactoring.fundInvoice(invoiceId02, upfrontBps, address(0));
        vm.stopPrank();

        // Fast forward time by 30 days
        vm.warp(block.timestamp + 60 days);

        // alice pays second invoice
        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        uint ppsAfterSecondRepayment = vault.pricePerShare();
        assertGt(ppsAfterSecondRepayment, ppsAfterFirstRepayment, "Price per share should increase after second repayment");

        // alice redeems half of her balance 
        uint256 sharesToWithdraw = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.redeem(sharesToWithdraw, alice, alice);
        vm.stopPrank();

        uint ppsAfterRedemption = vault.pricePerShare();

        assertEq(ppsAfterSecondRepayment, ppsAfterRedemption, "Price per share should remain the same after partial redemption");
    }
}

