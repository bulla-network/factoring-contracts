
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


contract TestDepositAndRedemption is CommonSetup {
    function testWhitelistDeposit() public {
        vm.startPrank(userWithoutPermissions);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", userWithoutPermissions));
        bullaFactoring.deposit(1 ether, alice);
        vm.stopPrank();
    }
    
    function testFundBalanceGoesToZero() public {
        uint256 initialBalanceAlice = asset.balanceOf(alice);
        uint256 initialDepositAlice = 10 ether;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Alice redeems all her funds
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        uint256 aliceBalanceAfterRedemption = asset.balanceOf(alice);
        assertEq(aliceBalanceAfterRedemption, initialBalanceAlice, "Alice's balance should be equal to her initial deposit after redemption");

        // New depositor Bob comes in
        uint256 initialDepositBob = 20 ether;
        vm.startPrank(bob);
        bullaFactoring.deposit(initialDepositBob, bob);
        vm.stopPrank();

        uint256 pricePerShareAfterNewDeposit = bullaFactoring.pricePerShare();
        assertEq(pricePerShareAfterNewDeposit, bullaFactoring.SCALING_FACTOR(), "Price should go back to the scaling factor for new depositor in empty asset vault");
    }
    
    function testAvailableAssetsLessThanTotal() public {
        // Alice deposits into the fund
        uint256 initialDepositAlice = 20000000000000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDepositAlice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Bob funds an invoice
        uint invoiceIdAmount = 10000000; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceIdAmount);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();
    
        bullaFactoring.reconcileActivePaidInvoices();

        uint feesAndTax =  bullaFactoring.adminFeeBalance() + bullaFactoring.protocolFeeBalance() + bullaFactoring.impairReserve() + bullaFactoring.taxBalance();

        assertEq(bullaFactoring.totalAssets(), bullaFactoring.availableAssets() + feesAndTax, "Available Assets should be lower than total assets by the sum of fees and tax");
    }

    function testInvestorRedeemsAllFunds() public {
        assertEq(bullaFactoring.totalSupply(), 0, "Total supply should be 0");
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice's balance should start at 0");

        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint aliceInitialBalance = asset.balanceOf(alice);

        uint256 initialDeposit = 200000;
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
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Alice redeems all her funds
        vm.startPrank(alice);
        uint redeemedAmount = bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        uint aliceBalanceAfterRedemption = asset.balanceOf(alice);

        assertTrue(redeemedAmount > initialDeposit, "Alice's redeem amount should be greater than her initial deposit after redemption");

        assertGt(aliceBalanceAfterRedemption + invoiceAmount, aliceInitialBalance , "Alice's balance should be greater than her initial deposit after redemption");

        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice's balance should be 0 after full redemption");

        bullaFactoring.withdrawAdminFees(); 
    }

    function testMaxRedemtionIsZeroAfterAllRedemptions() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
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
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Alice redeems all her funds
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(bullaFactoring.maxRedeem(), 0, "maxRedeem should be zero");
        assertEq(bullaFactoring.availableAssets(), 0, "availableAssets should be zero");
    }

    function testDepositAndRedemptionWithImpairReserve() public {
        interestApr = 2000;
        upfrontBps = 10000;

        uint initialImpairReserve = 50000; 
        asset.approve(address(bullaFactoring), initialImpairReserve);
        bullaFactoring.setImpairReserve(initialImpairReserve);

        assertEq(bullaFactoring.impairReserve(), initialImpairReserve, "Impair reserve should be set to 500");

        uint256 initialDeposit = 3000000; // deposit 3 USDC
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

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

        // alice pays both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();

        // reconcile redeemed invoice to adjust the price
        bullaFactoring.reconcileActivePaidInvoices();
       
        assertEq(bullaFactoring.availableAssets(), bullaFactoring.calculateCapitalAccount(), "Available assets should be equal to capital account");
        assertEq(bullaFactoring.balanceOf(alice), bullaFactoring.maxRedeem(), "Alice balance should be equal to maxRedeem");

        uint amountToRedeem = bullaFactoring.maxRedeem();

        // Alice redeems all her shares
        vm.prank(alice);
        bullaFactoring.redeem(amountToRedeem, alice, alice);
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();

        // withdraw all fess
        bullaFactoring.withdrawAdminFees();
        assertEq(bullaFactoring.adminFeeBalance(), 0, "Admin fee balance should be 0");
        bullaFactoring.withdrawTaxBalance();
        assertEq(bullaFactoring.taxBalance(), 0, "Tax balance should be 0");

        vm.prank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be 0");
        vm.stopPrank();

        assertEq(asset.balanceOf(address(bullaFactoring)) - bullaFactoring.impairReserve(), 0, "Bulla Factoring should have no balance left, net of impair reserve");
    }

    function testBalanceOfFundShouldBeZeroAfterAllFeeWithdrawals() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
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
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Alice redeems all her funds
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(bullaFactoring.maxRedeem(), 0, "maxRedeem should be zero");
        assertEq(bullaFactoring.availableAssets(), 0, "availableAssets should be zero");
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");

        // withdraw all fess
        bullaFactoring.withdrawAdminFees();
        assertEq(bullaFactoring.adminFeeBalance(), 0, "Admin fee balance should be 0");
        bullaFactoring.withdrawTaxBalance();
        assertEq(bullaFactoring.taxBalance(), 0, "Tax balance should be 0");

        vm.prank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be 0");
        vm.stopPrank();

        assertEq(asset.balanceOf(address(bullaFactoring)) - bullaFactoring.impairReserve(), 0, "Bulla Factoring should have no balance left, net of impair reserve");
    }

    function testDepositPriceDeclinesWhenAccruedProfits() public {
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 100000;
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 10000000;
        vm.startPrank(alice);
        uint shares1 = bullaFactoring.deposit(initialDeposit, alice);
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

        // Simulate 30 days pass, hence some accrued interest in the pool
        vm.warp(block.timestamp + 30 days);

        // Alice deposits again
        vm.startPrank(alice);
        uint shares2 = bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        assertGt(shares1, shares2, "Shares issued should be reduced when there is accrued interest in the pool");
    }

    function testEmptyVaultStillAbleToDeposit() public {
        dueBy = block.timestamp + 30 days;
        uint256 invoiceAmount = 100000000000;
        interestApr = 1000; // 10% APR
        upfrontBps = 10000; // 100% upfront

        uint256 initialDeposit = 100000000000;
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

        (, uint256 adminFee, uint256 targetInterest, uint256 targetProtocolFee,) = bullaFactoring.calculateTargetFees(invoiceId, 10000);

        // Simulate impairment
        vm.warp(block.timestamp + 100 days);

        (, uint256[] memory impairedInvoices) = bullaFactoring.viewPoolStatus();

        assertEq(impairedInvoices.length, 1, "There should be one impaired invoice");

        assertEq(asset.balanceOf(address(bullaFactoring)), adminFee + targetInterest + targetProtocolFee, "There should be no assets left in the pool, net of fees");

        // Alice never pays the invoices
        // fund owner impaires both invoices
        uint initialImpairReserve = 50000; 
        asset.approve(address(bullaFactoring), initialImpairReserve);
        bullaFactoring.setImpairReserve(initialImpairReserve);
        bullaFactoring.impairInvoice(invoiceId);

        // Alice deposits again
        vm.startPrank(alice);
        uint shares = bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Shares still get issued if there are no profits and all depositors money is lost");
    }
}

