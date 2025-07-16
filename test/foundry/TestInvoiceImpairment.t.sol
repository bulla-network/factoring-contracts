// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
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


contract TestInvoiceImpairment is CommonSetup {
    event InvoiceImpaired(uint256 indexed invoiceId, uint256 lossAmount, uint256 gainAmount);
    event ImpairReserveChanged(uint256 newImpairReserve);

    function testImparedReserve() public {
        uint initialImpairReserve = 500; 
        asset.approve(address(bullaFactoring), initialImpairReserve);
        
        vm.expectEmit(true, true, true, true);
        emit ImpairReserveChanged(initialImpairReserve);
        bullaFactoring.setImpairReserve(initialImpairReserve);

        interestApr = 3000;
        upfrontBps = 8000;

        uint256 initialDeposit = 900000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId01Amount = 10000000;
        uint256 invoiceId01 = createClaim(bob, alice, invoiceId01Amount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        uint invoiceId02Amount = 90000000;
        uint256 invoiceId02 = createClaim(bob, alice, invoiceId02Amount, dueBy);
        bullaClaim.approve(address(bullaFactoring), invoiceId02);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId02, interestApr, spreadBps, upfrontBps, minDays, 0);
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


        uint256 dueByNew = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId03Amount = 10000;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueByNew);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps, address(0));
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();
        IBullaFactoringV2.FundInfo memory fundInfoBefore = bullaFactoring.getFundInfo();
        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();

        // fund cannot impair an active invoice which is not classified as impaired
        vm.expectRevert(abi.encodeWithSignature("InvoiceNotImpaired()"));
        bullaFactoring.impairInvoice(invoiceId03);

        // Fast forward time by 100 days to simulate the invoice becoming impaired
        vm.warp(block.timestamp + 100 days);

        (, uint256[] memory impairedInvoices) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoices.length, 1);

        vm.expectEmit(true, false, false, false);
        emit InvoiceImpaired(invoiceId03, 0, 0);

        // fund impares the third invoice
        bullaFactoring.impairInvoice(invoiceId03);

        (, uint256[] memory impairedInvoicesAfter) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoicesAfter.length, 0);

        // reconcile redeemed invoice to make accounting adjustments
        bullaFactoring.reconcileActivePaidInvoices();
        IBullaFactoringV2.FundInfo memory fundInfoAfterImpairmentyFund = bullaFactoring.getFundInfo();
        uint256 capitalAccountAfterImpair = bullaFactoring.calculateCapitalAccount();

        assertTrue(capitalAccountBefore > capitalAccountAfterImpair, "Realized gain decreases if invoice is impaired by fund");
        assertTrue(fundInfoBefore.impairReserve > fundInfoAfterImpairmentyFund.impairReserve, "Impair reserve should decline after the fund has impaired an invoice");
        assertTrue(fundInfoBefore.fundBalance < fundInfoAfterImpairmentyFund.fundBalance, "Fund balance should rise after fund impaired an invoice");

        // cannot unfactor again the same invoice
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyImpairedByFund()"));
        bullaFactoring.impairInvoice(invoiceId03);

        // alice pays impaired invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId03, invoiceId03Amount);
        vm.stopPrank();

        (uint256[] memory paidInvoicesAfter, ) = bullaFactoring.viewPoolStatus();
        assertEq(paidInvoicesAfter.length, 1);

        bullaFactoring.reconcileActivePaidInvoices();

        uint256 capitalAccountAfterPayment = bullaFactoring.calculateCapitalAccount();
        
        assertTrue(capitalAccountAfterImpair < capitalAccountAfterPayment, "Realized gain increases when invoice impaired by fund gets paid");
    }

    function testChangingGracePeriodChangesAbilityToImpairInvoice() public {
        interestApr = 3000;
        upfrontBps = 8000;

        uint256 initialDeposit = 900000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 dueByNew = block.timestamp + 30 days;

        vm.startPrank(bob);
        uint invoiceId03Amount = 10000;
        uint256 invoiceId03 = createClaim(bob, alice, invoiceId03Amount, dueByNew);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId03, interestApr, spreadBps, upfrontBps, minDays, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId03);
        bullaFactoring.fundInvoice(invoiceId03, upfrontBps, address(0));
        vm.stopPrank();


        // Fast forward 5 days after due date
        vm.warp(block.timestamp + 35 days);

        (, uint256[] memory impairedInvoicesBefore) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoicesBefore.length, 0);

        vm.startPrank(address(this));
        bullaFactoring.setGracePeriodDays(0);
        vm.stopPrank();

        (, uint256[] memory impairedInvoicesAfter) = bullaFactoring.viewPoolStatus();
        assertEq(impairedInvoicesAfter.length, 1);
       }
}
