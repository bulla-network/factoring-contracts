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


contract TestWithdraw is CommonSetup {    
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
        vault.depositFrom(alice, initialDeposit);
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
        uint aliceBalance = bullaFactoring.balanceOf(alice);
        uint assetsToWithdraw = bullaFactoring.convertToAssets(aliceBalance);
        bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        uint aliceBalanceAfterRedemption = asset.balanceOf(alice);

        assertTrue(assetsToWithdraw > initialDeposit, "Alice's withdraw amount should be greater than her initial deposit after withdrawal");

        assertGt(aliceBalanceAfterRedemption + invoiceAmount, aliceInitialBalance , "Alice's balance should be greater than her initial deposit after redemption");

        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice's balance should be 0 after full withdrawal");

        bullaFactoring.withdrawAdminFees(); 
    }

     function testWithdrawIsEquivalentToRedemption() public {
        uint256 initialDeposit = 1000000000000000; // 1,000,000 USDC
        // initial deposit
        vm.startPrank(alice);
        vault.depositFrom(alice, initialDeposit);
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
        bullaFactoring.fundInvoice(invoiceId1, 10000);
        vm.stopPrank();

        // Simulate invoices being paid on time
        vm.warp(dueDate - 1);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId1, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Alice redeems all her funds
        vm.startPrank(alice);
        uint assetsRedeemed = vault.redeemTo(alice, 10_000);
        vm.stopPrank();
        
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice redeem all her shares");
                
        dueDate = block.timestamp + 30 days;
        // second identical deposit
        vm.startPrank(alice);
        uint256 initialShares = vault.depositFrom(alice, initialDeposit);
        vm.stopPrank();

        // Create and fund second invoice, identical to the first
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueDate);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, 10000, minDays); // 100% upfront
        vm.stopPrank();

        vm.startPrank(bob);
        bullaClaimERC721.approve(address(bullaFactoring), invoiceId2);
        bullaFactoring.fundInvoice(invoiceId2, 10000);
        vm.stopPrank();

        // Simulate invoices being paid on time
        vm.warp(dueDate - 1);

        vm.startPrank(alice);
        bullaClaim.payClaim(invoiceId2, invoiceAmount);
        vm.stopPrank();

        bullaFactoring.reconcileActivePaidInvoices();

        // Alice withdraws all her funds
        vm.startPrank(alice);
        uint aliceBalance = bullaFactoring.balanceOf(alice);
        uint sharesWithdrawn = bullaFactoring.withdraw(vault.totalAssets() + vault.globalTotalAtRiskCapital(), alice, alice);
        vm.stopPrank();
        
        assertEq(aliceBalance, sharesWithdrawn, "shares withdrawn equals alice's balance");
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice redeem all her shares");
        assertEq(sharesWithdrawn, initialShares, "Assets withdrawn should be equal to assets redeemed in identical scenario");
    }

    function testAvailableAssetIsZeroAfterAllWithdrawals() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 100000; // Invoice amount is $100000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 200000;
        vm.startPrank(alice);
        vault.depositFrom(alice, initialDeposit);
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

        // Alice withdraws all her funds
        vm.startPrank(alice);
        uint aliceBalance = bullaFactoring.balanceOf(alice);
        uint assetsToWithdraw = bullaFactoring.convertToAssets(aliceBalance);

        assertEq(bullaFactoring.maxWithdraw(alice), assetsToWithdraw, "Alice is about to withdraw the most that she can");

        bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets() + vault.globalTotalAtRiskCapital(), 0, "availableAssets should be zero");
    }

    function testBalanceOfFundShouldBeZeroAfterAllFeeWithdrawals() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 10000000; // Invoice amount is $10000000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 20000000;
        vm.startPrank(alice);
        vault.depositFrom(alice, initialDeposit);
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

        // Alice withdraws all her funds
        vm.startPrank(alice);
        uint aliceBalance = bullaFactoring.balanceOf(alice);
        uint assetsToWithdraw = bullaFactoring.convertToAssets(aliceBalance);
        bullaFactoring.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets() + vault.globalTotalAtRiskCapital(), 0, "availableAssets should be zero");
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");

        // withdraw all fess
        bullaFactoring.withdrawAdminFees();
        assertEq(bullaFactoring.adminFeeBalance(), 0, "Admin fee balance should be 0");

        vm.prank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be 0");
        vm.stopPrank();

        assertEq(asset.balanceOf(address(bullaFactoring)) - bullaFactoring.impairReserve(), 0, "Bulla Factoring should have no balance left, net of impair reserve");
    }

    function testConvertToAssetsReturnsSharesWhenNoSupply() public {
        vm.startPrank(alice);
        assertEq(bullaFactoring.convertToAssets(1000), 1000, "Assets should be equal to shares if no shares/no capital deposited");
        vm.stopPrank();

    }

    function testOnlyAuthorizedDepositorsCanWithdraw() public {
        vm.startPrank(userWithoutPermissions);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", userWithoutPermissions));
        bullaFactoring.withdraw(1 ether, userWithoutPermissions, alice);
        vm.stopPrank();
    }

    function testOnlyAuthorizedOwnersCanWithdraw() public {
        uint256 initialDeposit = 20000000;

         // Alice deposits
        vm.startPrank(alice);
        vault.depositFrom(alice, initialDeposit);

        // Alice sends BFTs to unauthorized user
        uint sharesBalance = bullaFactoring.balanceOf(alice);
        IERC20(address(bullaFactoring)).transfer(userWithoutPermissions, sharesBalance);

        // unauthorized user permits Alice
        vm.startPrank(userWithoutPermissions);
        IERC20(address(bullaFactoring)).approve(alice, initialDeposit);
        vm.stopPrank();

        vm.startPrank(alice);
        // Alice calls redeem/withdraw for unauthorized user
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", userWithoutPermissions));
        bullaFactoring.withdraw(initialDeposit, userWithoutPermissions, userWithoutPermissions);
        vm.stopPrank();
    }
}

