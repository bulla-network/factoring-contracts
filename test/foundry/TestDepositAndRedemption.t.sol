
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
        uint256 initialDepositAlice = 2000;
        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), initialDepositAlice);
        bullaFactoring.deposit(initialDepositAlice, alice);
        vm.stopPrank();

        // Bob funds an invoice
        uint invoiceIdAmount = 100; // Amount of the invoice
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, upfrontBps, minDays);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps);
        vm.stopPrank();
    
        assertTrue(bullaFactoring.totalAssets() > bullaFactoring.availableAssets());

        uint fundedAmount = bullaFactoring.getFundedAmount(invoiceId);

        assertEq(bullaFactoring.totalAssets() - fundedAmount, bullaFactoring.availableAssets(), "Available Assets should be the differenct of total assets and what has been funded");
    }

    function testInvestorWithdrawAllFunds() public {
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

        assertEq(bullaFactoring.adminFeeBalance(), 0, "Fees should be 0 after withdrawing");
    }
}