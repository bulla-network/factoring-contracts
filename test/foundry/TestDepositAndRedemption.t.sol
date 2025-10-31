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


contract TestDepositAndRedemption is CommonSetup {
    event InvoiceApproved(uint256 indexed invoiceId, uint256 validUntil, IBullaFactoringV2.FeeParams feeParams);
    event InvoiceFunded(uint256 indexed invoiceId, uint256 fundedAmount, address indexed originalCreditor, uint256 dueDate, uint16 upfrontBps, uint256 protocolFee);
    event ActivePaidInvoicesReconciled(uint256[] paidInvoiceIds);
    event InvoicePaid(uint256 indexed invoiceId, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee, uint256 fundedAmountNet, uint256 kickbackAmount, address indexed originalCreditor);

    event ProtocolFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event AdminFeesWithdrawn(address indexed bullaDao, uint256 amount);
    event SpreadGainsWithdrawn(address indexed owner, uint256 amount);

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

        assertEq(1000, bullaFactoring.previewRedeem(1000), "Price should go back to the scaling factor for new depositor in empty asset vault");
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
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceIdAmount, dueBy);
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceIdAmount);
        bullaClaim.payClaim(invoiceId, invoiceIdAmount);
        vm.stopPrank();
    
        

        uint fees =  bullaFactoring.adminFeeBalance() + bullaFactoring.protocolFeeBalance() + bullaFactoring.impairReserve();

        assertEq(asset.balanceOf(address(bullaFactoring)), bullaFactoring.totalAssets() + fees, "Available Assets should be lower than total assets by the sum of fees");
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
        IBullaFactoringV2.FeeParams memory expectedFeeParams = IBullaFactoringV2.FeeParams({
            targetYieldBps: interestApr,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            protocolFeeBps: protocolFeeBps,
            adminFeeBps: adminFeeBps
        });
        
        vm.expectEmit(true, true, true, true);
        emit InvoiceApproved(invoiceId, block.timestamp + bullaFactoring.approvalDuration(), expectedFeeParams);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        
        // Calculate expected funded amount
        (, , , , , uint256 expectedFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
        
        vm.expectEmit(true, true, true, true);
        emit InvoiceFunded(invoiceId, expectedFundedAmount, bob, dueBy, upfrontBps, 250);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();        

        // Alice redeems all her funds
        vm.startPrank(alice);
        uint redeemedAmount = bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        uint aliceBalanceAfterRedemption = asset.balanceOf(alice);

        assertTrue(redeemedAmount > initialDeposit, "Alice's redeem amount should be greater than her initial deposit after redemption");

        assertGt(aliceBalanceAfterRedemption + invoiceAmount, aliceInitialBalance , "Alice's balance should be greater than her initial deposit after redemption");

        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice's balance should be 0 after full redemption");

        // Expect fee withdrawal events
        uint256 adminFeeAmount = bullaFactoring.adminFeeBalance();
        
        if (adminFeeAmount > 0) {
            vm.expectEmit(true, true, true, true);
            emit AdminFeesWithdrawn(address(this), adminFeeAmount);
        }
        bullaFactoring.withdrawAdminFeesAndSpreadGains(); 
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        

        // Alice redeems all her funds
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(bullaFactoring.maxRedeem(), 0, "maxRedeem should be zero");
        assertEq(bullaFactoring.totalAssets(), 0, "availableAssets should be zero");
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
        bullaFactoring.approveInvoice(invoiceId01, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId01);
        bullaFactoring.fundInvoice(invoiceId01, upfrontBps, address(0));
        vm.stopPrank();

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
        vm.warp(block.timestamp + 30 days);

        // alice pays both invoices
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 1000 ether);
        bullaClaim.payClaim(invoiceId01, invoiceId01Amount);
        bullaClaim.payClaim(invoiceId02, invoiceId02Amount);
        vm.stopPrank();
       
        assertEq(bullaFactoring.totalAssets(), bullaFactoring.calculateCapitalAccount(), "Available assets should be equal to capital account");
        assertEq(bullaFactoring.balanceOf(alice), bullaFactoring.maxRedeem(), "Alice balance should be equal to maxRedeem");

        uint amountToRedeem = bullaFactoring.maxRedeem();

        // Alice redeems all her shares
        vm.prank(alice);
        bullaFactoring.redeem(amountToRedeem, alice, alice);
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");
        vm.stopPrank();

        // withdraw all fess
        bullaFactoring.withdrawAdminFeesAndSpreadGains();
        assertEq(bullaFactoring.adminFeeBalance(), 0, "Admin fee balance should be 0");

        vm.prank(bullaDao);
        bullaFactoring.withdrawProtocolFees();
        assertEq(bullaFactoring.protocolFeeBalance(), 0, "Protocol fee balance should be 0");
        vm.stopPrank();

        assertEq(asset.balanceOf(address(bullaFactoring)) - bullaFactoring.impairReserve(), 0, "Bulla Factoring should have no balance left, net of impair reserve");
    }

    function testBalanceOfFundShouldBeZeroAfterAllFeeWithdrawals() public {
        dueBy = block.timestamp + 60 days; // Invoice due in 60 days
        uint256 invoiceAmount = 10000000; // Invoice amount is $10000000
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 20000000;
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Simulate debtor paying in 30 days instead of 60
        uint256 actualDaysUntilPayment = 30;
        vm.warp(block.timestamp + actualDaysUntilPayment * 1 days);

        // Debtor pays the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        

        // Alice redeems all her funds
        vm.startPrank(alice);
        bullaFactoring.redeem(bullaFactoring.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertEq(bullaFactoring.maxRedeem(), 0, "maxRedeem should be zero");
        assertEq(bullaFactoring.totalAssets(), 0, "availableAssets should be zero");
        assertEq(bullaFactoring.balanceOf(alice), 0, "Alice should have no balance left");

        // withdraw all fess
        bullaFactoring.withdrawAdminFeesAndSpreadGains();
        assertEq(bullaFactoring.adminFeeBalance(), 0, "Admin fee balance should be 0");

        uint256 protocolFeeAmount = bullaFactoring.protocolFeeBalance();
        vm.prank(bullaDao);
        if (protocolFeeAmount > 0) {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeesWithdrawn(bullaDao, protocolFeeAmount);
        }
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
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
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        (, uint256 adminFee, uint256 targetInterest, uint256 targetSpread, uint256 targetProtocolFee, ) = bullaFactoring.calculateTargetFees(invoiceId, 10000);

        // Simulate impairment
        vm.warp(block.timestamp + 100 days);

        uint256[] memory impairedInvoices = bullaFactoring.viewPoolStatus();

        assertEq(impairedInvoices.length, 1, "There should be one impaired invoice");

        assertEq(asset.balanceOf(address(bullaFactoring)), adminFee + targetInterest + targetProtocolFee + targetSpread, "There should be no assets left in the pool, net of fees");

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

    function testPreviewRedeemReturnsSameAsActualRedeem() public {
        dueBy = block.timestamp + 30 days;
        interestApr = 1000; // 10% APR
        upfrontBps = 10000; // 100% upfront

        uint256 initialDeposit = 100000000000;
        uint256 invoiceAmount =   50000000000;

        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Preview redeem before funding invoice
        uint256 previewRedeem1 = bullaFactoring.previewRedeem(bullaFactoring.balanceOf(alice) / 2);

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Preview redeem after funding invoice
        uint256 previewRedeem2 = bullaFactoring.previewRedeem(bullaFactoring.balanceOf(alice) / 2);

        assertEq(previewRedeem1, previewRedeem2, "previewed redemption amounts should be the same after invoice funded");

        // Alice redeems all her funds
        vm.startPrank(alice);
        uint256 redemption = bullaFactoring.redeem(bullaFactoring.balanceOf(alice) / 2, alice, alice);
        vm.stopPrank();

        assertEq(previewRedeem2, redemption, "previewed redemption amount is the same as actual redemption amount");
    }

    function testPreviewWithdrawReturnsSameAsActualWithdraw() public {
        dueBy = block.timestamp + 30 days;
        interestApr = 1000; // 10% APR
        upfrontBps = 10000; // 100% upfront

        uint256 initialDeposit = 100000000000;
        uint256 invoiceAmount =   50000000000;

        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Preview withdraw before funding invoice
        uint256 previewWithdraw1 = bullaFactoring.previewWithdraw(initialDeposit / 2);

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Preview withdraw after funding invoice
        uint256 previewWithdraw2 = bullaFactoring.previewWithdraw(initialDeposit / 2);

        assertEq(previewWithdraw1, previewWithdraw2, "previewed withdrawal amounts should be the same after invoice funded");

        // Alice withdraws all her funds
        vm.startPrank(alice);
        uint256 withdrawal = bullaFactoring.withdraw(initialDeposit / 2, alice, alice);
        vm.stopPrank();

        assertEq(previewWithdraw2, withdrawal, "previewed withdrawal amount is the same as actual withdrawal amount");
    }

    function testPreviewdepositReturnsSameAsActualdeposit() public {
        dueBy = block.timestamp + 30 days;
        interestApr = 1000; // 10% APR
        upfrontBps = 10000; // 100% upfront

        uint256 initialDeposit = 100000000000;
        uint256 invoiceAmount =   50000000000;

        // Preview deposit before everything
        uint256 previewDeposit0 = bullaFactoring.previewDeposit(initialDeposit);

        vm.startPrank(alice);
        uint256 deposit0 = bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        assertEq(previewDeposit0, deposit0, "previewed deposit amount is the same as actual deposit amount");

        // Preview deposit before funding invoice
        uint256 previewDeposit1 = bullaFactoring.previewDeposit(initialDeposit);

        vm.startPrank(alice);
        uint256 deposit1 = bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        assertEq(previewDeposit1, deposit1, "previewed deposit amount is the same as actual deposit amount");

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Preview deposit after funding invoice
        uint256 previewDeposit2 = bullaFactoring.previewDeposit(initialDeposit);

        assertEq(previewDeposit2, previewDeposit1, "depositing after an invoice is funded should grant the same shares as before");

        // Alice deposits again
        vm.startPrank(alice);
        uint256 deposit2 = bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        assertEq(previewDeposit2, deposit2, "previewed deposit amount is the same as actual deposit amount");
    }

    function testDeductRealizedProfitInAccruedInterest() public {
        dueBy = block.timestamp + 30 days;
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 100000000000;
        uint256 invoiceAmount =   50000000000;

        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // After days of interest is not 0
        vm.warp(block.timestamp + 1 days);

        // Preview deposit after funded invoice but before partial claim payment
        uint256 previewDepositBefore = bullaFactoring.previewDeposit(initialDeposit);

        uint256 halfOfInvoiceAmount = invoiceAmount / 2;
        // Debtor pays half of the invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), halfOfInvoiceAmount);
        bullaClaim.payClaim(invoiceId, halfOfInvoiceAmount);
        vm.stopPrank();
        
        // Preview deposit after funded invoice but before partial claim payment
        uint256 previewDepositAfterHalfPay = bullaFactoring.previewDeposit(initialDeposit);
        
        assertEq(previewDepositAfterHalfPay, previewDepositBefore, "payments that have not generated profit should not change accrued interest");

        uint256 invoiceRemainder = invoiceAmount - halfOfInvoiceAmount;

        // Debtor pays remainder before reconciliation
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceRemainder);
        bullaClaim.payClaim(invoiceId, invoiceRemainder);
        vm.stopPrank();

        // Preview deposit after claim payment
        uint256 previewDepositAfterFullPay = bullaFactoring.previewDeposit(initialDeposit);
        
        // Allow small margin of error for rounding differences in dailyInterestRate calculations (~0.000039%)
        assertApproxEqAbs(previewDepositAfterFullPay, previewDepositAfterHalfPay, 10000, "Reconciliation should not change deposit value");
    }

    function testAccuredInterestAfterImpairmentDecreases() public {
        dueBy = block.timestamp + 30 days;
        interestApr = 1000; // 10% APR
        upfrontBps = 8000; // 80% upfront

        uint256 initialDeposit = 100000000000;
        uint256 invoiceAmount =   50000000000;

        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);
        vm.stopPrank();

        // Creditor creates the invoice
        vm.startPrank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.stopPrank();

        // Underwriter approves the invoice
        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        // creditor funds the invoice
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Preview deposit before impairment
        uint256 previewDepositAtFunding = bullaFactoring.previewDeposit(initialDeposit);

        // Around due date
        vm.warp(block.timestamp + 30 days);

        // Preview deposit before impairment
        uint256 previewDepositBeforeImpairment = bullaFactoring.previewDeposit(initialDeposit);

        assertGt(previewDepositAtFunding, previewDepositBeforeImpairment, "Accrued interest should increase therefore a depositor gets less shares");

        // Around once invoice is impaired
        vm.warp(block.timestamp + 120 days);

        // Preview deposit after impairment
        uint256 previewDepositAfterImpairment = bullaFactoring.previewDeposit(initialDeposit);
        
        assertGt(previewDepositAfterImpairment, previewDepositBeforeImpairment, "Accrued interest should have decreased therefore a depositor gets more shares");
    }

    function testOnlyAuthorizedDepositorsCanRedeem() public {
        vm.startPrank(userWithoutPermissions);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", userWithoutPermissions));
        bullaFactoring.redeem(1 ether, userWithoutPermissions, alice);
        vm.stopPrank();
    }

    function testOnlyAuthorizedOwnersCanRedeem() public {
        uint256 initialDeposit = 20000000;
        
        // Alice deposits
        vm.startPrank(alice);
        bullaFactoring.deposit(initialDeposit, alice);

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
        bullaFactoring.redeem(sharesBalance, userWithoutPermissions, userWithoutPermissions);
        vm.stopPrank();
    }

    /*
    @dev this test passes, showing how inflations by traditional stealth deposits don't work since those funds aren't taken into consideration
    when calculating depositor shares.
    */
    function testDepositInflationAttack() public {
        address firstDepositor = makeAddr("firstDepositor");
        address secondDepositor = makeAddr("secondDepositor");

        uint256 firstDepositAmount = 1;
        uint256 secondDepositAmount = 1e18;
        uint256 inflationAmount = 100e18;

        permitUser(firstDepositor, true, firstDepositAmount + inflationAmount);
        permitUser(secondDepositor, true, secondDepositAmount);

        vm.startPrank(firstDepositor);
        uint256 firstDepositorShares = bullaFactoring.deposit(firstDepositAmount, firstDepositor);
        vm.stopPrank();

        // Inflation isn't tracked due to internal accounting logic
        vm.prank(address(firstDepositor));
        asset.transfer(address(bullaFactoring), inflationAmount);

        vm.startPrank(secondDepositor);
        uint256 secondDepositorShares = bullaFactoring.deposit(secondDepositAmount, secondDepositor);
        vm.stopPrank();

        assertEq(firstDepositorShares, 1, "First depositor should have 1 share");
        assertEq(secondDepositorShares, 1e18, "Second depositor should have 1e18 shares");
    }
}