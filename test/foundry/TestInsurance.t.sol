// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IBullaFactoringV2_2} from "../../contracts/interfaces/IBullaFactoring.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TestInsurance is CommonSetup {
    address insurerAddr = address(0x1999);

    // ============================================
    // 1. Insurance BPS validation (constructor + setter)
    // ============================================

    function testConstructorRevertsInsuranceFeeBpsOver10000() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, bullaFrendLend, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(10001), uint16(500), uint16(5000)
        );
    }

    function testConstructorRevertsImpairmentGrossGainBpsOver10000() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, bullaFrendLend, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(100), uint16(10001), uint16(5000)
        );
    }

    function testConstructorRevertsRecoveryProfitRatioBpsOver10000() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, bullaFrendLend, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(100), uint16(500), uint16(10001)
        );
    }

    function testConstructorRevertsImpairmentGrossGainBpsZero() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, bullaFrendLend, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(100), uint16(0), uint16(5000)
        );
    }

    function testSetInsuranceParamsRevertsInsuranceFeeBpsOver10000() public {
        vm.expectRevert();
        bullaFactoring.setInsuranceParams(10001, 500, 5000);
    }

    function testSetInsuranceParamsRevertsImpairmentGrossGainBpsOver10000() public {
        vm.expectRevert();
        bullaFactoring.setInsuranceParams(100, 10001, 5000);
    }

    function testSetInsuranceParamsRevertsRecoveryProfitRatioBpsOver10000() public {
        vm.expectRevert();
        bullaFactoring.setInsuranceParams(100, 500, 10001);
    }

    function testSetInsuranceParamsRevertsImpairmentGrossGainBpsZero() public {
        vm.expectRevert();
        bullaFactoring.setInsuranceParams(100, 0, 5000);
    }

    function testSetInsuranceParamsAcceptsMaxValues() public {
        bullaFactoring.setInsuranceParams(10000, 10000, 10000);
        assertEq(bullaFactoring.insuranceFeeBps(), 10000);
        assertEq(bullaFactoring.impairmentGrossGainBps(), 10000);
        assertEq(bullaFactoring.recoveryProfitRatioBps(), 10000);
    }

    // ============================================
    // 2. Insurance premium collection on funding
    // ============================================

    function testInsurancePremiumCollectedOnFunding() public {
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;

        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 insuranceBalanceAfter = bullaFactoring.insuranceBalance();

        // insuranceFeeBps is 100 (1%), initialInvoiceValue = 100000
        // premium = 100000 * 100 / 10000 = 1000
        uint256 expectedPremium = Math.mulDiv(invoiceAmount, bullaFactoring.insuranceFeeBps(), 10000);
        assertEq(insuranceBalanceAfter - insuranceBalanceBefore, expectedPremium, "Insurance balance should increase by premium amount");
        assertGt(expectedPremium, 0, "Premium should be non-zero");
    }

    function testInsurancePremiumHalfPaidInvoice() public {
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 50000;

        // Invoice 1: fully unpaid
        vm.prank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);

        // Invoice 2: half paid before factoring
        vm.prank(bob);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount / 2);
        bullaClaim.payClaim(invoiceId2, invoiceAmount / 2);
        vm.stopPrank();

        vm.startPrank(underwriter);
        bullaFactoring.approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, 0);
        bullaFactoring.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, 0);
        vm.stopPrank();

        (, , , , , uint256 insurancePremium1, ) = bullaFactoring.calculateTargetFees(invoiceId1, upfrontBps);
        (, , , , , uint256 insurancePremium2, ) = bullaFactoring.calculateTargetFees(invoiceId2, upfrontBps);

        assertEq(insurancePremium2, insurancePremium1 / 2, "Half-paid invoice should have half the insurance premium");
        assertGt(insurancePremium1, 0, "Full invoice premium should be non-zero");
        assertGt(insurancePremium2, 0, "Half-paid invoice premium should be non-zero");
    }

    function testInsuranceBalanceAccumulatesAcrossMultipleFundings() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 50000;

        // Create and fund 3 invoices
        uint256 totalExpectedPremium = 0;
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(bob);
            uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

            vm.prank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

            (, , , , , uint256 insurancePremium, ) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);
            totalExpectedPremium += insurancePremium;

            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            vm.stopPrank();
        }

        assertEq(bullaFactoring.insuranceBalance(), totalExpectedPremium, "Insurance balance should accumulate across fundings");
        assertGt(totalExpectedPremium, 0, "Total premium should be non-zero");
    }

    // ============================================
    // 3. Access control
    // ============================================

    function testOnlyInsurerCanImpair() public {
        uint256 invoiceId = _fundSingleInvoice(100000);
        vm.warp(block.timestamp + 91 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerNotInsurer()"));
        bullaFactoring.impairInvoice(invoiceId);
    }

    function testOnlyInsurerCanWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("CallerNotInsurer()"));
        bullaFactoring.withdrawInsuranceBalance();
    }

    function testOnlyOwnerCanSetInsurer() public {
        vm.prank(alice);
        vm.expectRevert();
        bullaFactoring.setInsurer(alice);
    }

    function testOnlyOwnerCanSetInsuranceParams() public {
        vm.prank(alice);
        vm.expectRevert();
        bullaFactoring.setInsuranceParams(200, 600, 6000);
    }

    function testSetInsurerUpdatesInsurer() public {
        address newInsurer = address(0x9999);
        bullaFactoring.setInsurer(newInsurer);
        assertEq(bullaFactoring.insurer(), newInsurer, "Insurer should be updated");
    }

    // ============================================
    // 4. Withdraw insurance balance
    // ============================================

    function testWithdrawInsuranceBalance() public {
        _fundSingleInvoice(100000);

        uint256 insuranceBalance = bullaFactoring.insuranceBalance();
        assertGt(insuranceBalance, 0, "Insurance balance should be non-zero after funding");

        uint256 insurerBalanceBefore = asset.balanceOf(insurerAddr);

        vm.prank(insurerAddr);
        bullaFactoring.withdrawInsuranceBalance();

        assertEq(bullaFactoring.insuranceBalance(), 0, "Insurance balance should be zero after withdrawal");
        assertEq(asset.balanceOf(insurerAddr) - insurerBalanceBefore, insuranceBalance, "Insurer should receive full balance");
    }

    function testWithdrawInsuranceBalanceZero() public {
        vm.prank(insurerAddr);
        bullaFactoring.withdrawInsuranceBalance();
        assertEq(bullaFactoring.insuranceBalance(), 0);
    }

    // ============================================
    // 5. Impairment with sufficient insurance
    // ============================================

    function testImpairInvoiceWithSufficientInsurance() public {
        // insuranceFeeBps=100 (1%), impairmentGrossGainBps=500 (5%)
        // Need 5x the invoice value in funded invoices to cover 1 impairment
        // Fund 6 invoices of 20000 each, then impair 1
        uint256 depositAmount = 600000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 20000;
        uint256[] memory invoiceIds = new uint256[](6);

        for (uint256 i = 0; i < 6; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 91 days);

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();
        // 6 invoices * 20000 * 1% = 1200 insurance balance
        // impairmentGrossGain = 20000 * 5% = 1000
        // outOfPocketCost = 0 since 1200 >= 1000

        (uint256 outstandingBalance, uint256 impairmentGrossGain, , , uint256 outOfPocketCost, ) = bullaFactoring.previewImpair(invoiceIds[0]);

        assertEq(outOfPocketCost, 0, "No out-of-pocket cost when insurance covers full impairment");
        assertEq(outstandingBalance, invoiceAmount, "Outstanding balance should equal full invoice amount");
        assertGt(impairmentGrossGain, 0, "Impairment gross gain should be non-zero");

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceIds[0]);

        assertEq(bullaFactoring.insuranceBalance(), insuranceBalanceBefore - impairmentGrossGain, "Insurance balance should decrease by gross gain");

        (bool isImpaired, uint256 purchasePrice, ) = bullaFactoring.impairmentInfo(invoiceIds[0]);
        assertTrue(isImpaired, "Invoice should be marked as impaired");
        assertEq(purchasePrice, impairmentGrossGain, "Purchase price should equal impairment gross gain");
    }

    // ============================================
    // 6. Impairment with insufficient insurance (out-of-pocket)
    // ============================================

    function testImpairInvoiceWithInsufficientInsurance() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 200000;

        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Insurance balance = 200000 * 1% = 2000
        // Impairment gross gain = 200000 * 5% = 10000
        // outOfPocketCost = 10000 - 2000 = 8000

        vm.warp(block.timestamp + 91 days);

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();
        (, uint256 impairmentGrossGain, , , uint256 outOfPocketCost, ) = bullaFactoring.previewImpair(invoiceId);

        assertGt(outOfPocketCost, 0, "Should have out-of-pocket cost");
        assertEq(outOfPocketCost, impairmentGrossGain - insuranceBalanceBefore, "Out-of-pocket should be difference");

        // Give insurer enough tokens to cover out-of-pocket
        asset.mint(insurerAddr, outOfPocketCost);
        vm.prank(insurerAddr);
        asset.approve(address(bullaFactoring), outOfPocketCost);

        uint256 insurerBalanceBefore = asset.balanceOf(insurerAddr);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.insuranceBalance(), 0, "Insurance balance should be zero");
        assertEq(insurerBalanceBefore - asset.balanceOf(insurerAddr), outOfPocketCost, "Insurer should pay out-of-pocket cost");

        (bool isImpaired, , ) = bullaFactoring.impairmentInfo(invoiceId);
        assertTrue(isImpaired, "Invoice should be marked as impaired");
    }

    // ============================================
    // 7. Double impairment reverts
    // ============================================

    function testDoubleImpairmentReverts() public {
        uint256 invoiceId = _fundAndBuildInsurance(100000);
        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        vm.prank(insurerAddr);
        vm.expectRevert(abi.encodeWithSignature("InvoiceAlreadyImpaired()"));
        bullaFactoring.impairInvoice(invoiceId);
    }

    // ============================================
    // 8. Recovery flow - impaired invoice gets paid
    // ============================================

    function testRecoveryOfImpairedInvoice() public {
        uint256 invoiceAmount = 100000;
        uint256 invoiceId = _fundAndBuildInsurance(invoiceAmount);
        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 insuranceBalanceAfterImpair = bullaFactoring.insuranceBalance();

        // Debtor pays the full invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint256 insuranceBalanceAfterRecovery = bullaFactoring.insuranceBalance();
        assertGt(insuranceBalanceAfterRecovery, insuranceBalanceAfterImpair, "Insurance balance should increase after recovery");
    }

    function testRecoveryProfitSplit() public {
        uint256 invoiceAmount = 100000;
        uint256 invoiceId = _fundAndBuildInsurance(invoiceAmount);
        vm.warp(block.timestamp + 91 days);

        (, uint256 impairmentGrossGain, , , , uint256 paidAmountAtImpairment) = bullaFactoring.previewImpair(invoiceId);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 insuranceBalanceAfterImpair = bullaFactoring.insuranceBalance();
        uint256 paidInvoicesGainBefore = bullaFactoring.paidInvoicesGain();

        // Debtor pays the full invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        uint256 recoveredAmount = invoiceAmount - paidAmountAtImpairment;

        if (recoveredAmount > impairmentGrossGain) {
            uint256 excess = recoveredAmount - impairmentGrossGain;
            uint256 expectedInvestorShare = Math.mulDiv(excess, bullaFactoring.recoveryProfitRatioBps(), 10000);
            uint256 expectedInsuranceShare = recoveredAmount - expectedInvestorShare;

            assertEq(
                bullaFactoring.insuranceBalance() - insuranceBalanceAfterImpair,
                expectedInsuranceShare,
                "Insurance should receive its share"
            );
            assertEq(
                bullaFactoring.paidInvoicesGain() - paidInvoicesGainBefore,
                expectedInvestorShare,
                "Investors should receive their share"
            );
        } else {
            assertEq(
                bullaFactoring.insuranceBalance() - insuranceBalanceAfterImpair,
                recoveredAmount,
                "All recovery should go to insurance when no excess"
            );
        }
    }

    // ============================================
    // 9. previewImpair returns correct values
    // ============================================

    function testPreviewImpairValues() public {
        uint256 invoiceAmount = 100000;
        uint256 invoiceId = _fundSingleInvoice(invoiceAmount);
        vm.warp(block.timestamp + 91 days);

        (uint256 outstandingBalance, uint256 impairmentGrossGain, uint256 adminFeeOwed, uint256 impairmentNetGain, uint256 outOfPocketCost, uint256 currentPaidAmount) = bullaFactoring.previewImpair(invoiceId);

        assertEq(outstandingBalance, invoiceAmount, "Outstanding balance should equal invoice amount");
        assertEq(currentPaidAmount, 0, "No payments have been made");

        uint256 expectedGrossGain = Math.mulDiv(outstandingBalance, bullaFactoring.impairmentGrossGainBps(), 10000);
        assertEq(impairmentGrossGain, expectedGrossGain, "Gross gain calculation should be correct");

        if (impairmentGrossGain > adminFeeOwed) {
            assertEq(impairmentNetGain, impairmentGrossGain - adminFeeOwed, "Net gain should be gross minus admin fee");
        } else {
            assertEq(impairmentNetGain, 0, "Net gain should be 0 when admin fee exceeds gross gain");
        }

        uint256 insuranceBal = bullaFactoring.insuranceBalance();
        if (impairmentGrossGain > insuranceBal) {
            assertEq(outOfPocketCost, impairmentGrossGain - insuranceBal, "Out-of-pocket should be difference");
        } else {
            assertEq(outOfPocketCost, 0, "No out-of-pocket when insurance covers all");
        }
    }

    function testPreviewImpairPartiallyPaidInvoice() public {
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;

        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        uint256 partialPayment = 40000;
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), partialPayment);
        bullaClaim.payClaim(invoiceId, partialPayment);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        (uint256 outstandingBalance, uint256 impairmentGrossGain, , , , uint256 currentPaidAmount) = bullaFactoring.previewImpair(invoiceId);

        assertEq(currentPaidAmount, partialPayment, "Current paid amount should reflect partial payment");
        assertEq(outstandingBalance, invoiceAmount - partialPayment, "Outstanding balance should be reduced by payment");

        uint256 expectedGrossGain = Math.mulDiv(outstandingBalance, bullaFactoring.impairmentGrossGainBps(), 10000);
        assertEq(impairmentGrossGain, expectedGrossGain, "Gross gain should be based on outstanding balance");
    }

    // ============================================
    // 10. Impairment updates investor gains and admin fees
    // ============================================

    function testImpairmentUpdatesGainsAndFees() public {
        uint256 invoiceId = _fundAndBuildInsurance(100000);
        vm.warp(block.timestamp + 91 days);

        uint256 paidInvoicesGainBefore = bullaFactoring.paidInvoicesGain();
        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();

        (, , uint256 adminFeeOwed, uint256 impairmentNetGain, , ) = bullaFactoring.previewImpair(invoiceId);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.paidInvoicesGain() - paidInvoicesGainBefore, impairmentNetGain, "Investor gains should increase by net gain");
        assertEq(bullaFactoring.adminFeeBalance() - adminFeeBalanceBefore, adminFeeOwed, "Admin fee balance should increase by admin fee owed");
    }

    // ============================================
    // 11. Impairment records to impairedInvoices array
    // ============================================

    function testImpairmentAddsToImpairedInvoicesArray() public {
        uint256 invoiceId = _fundAndBuildInsurance(100000);
        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.impairedInvoices(0), invoiceId, "Impaired invoice should be in array");
    }

    // ============================================
    // 12. Recovery removes from impairedInvoices array
    // ============================================

    function testRecoveryRemovesFromImpairedInvoicesArray() public {
        uint256 invoiceAmount = 100000;
        uint256 invoiceId = _fundAndBuildInsurance(invoiceAmount);
        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.impairedInvoices(0), invoiceId);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // impairedInvoices array should be empty now
        vm.expectRevert();
        bullaFactoring.impairedInvoices(0);
    }

    // ============================================
    // 13. Multiple impairments
    // ============================================

    function testMultipleImpairments() public {
        // Fund many invoices to build sufficient insurance for 3 impairments
        // Each impairment costs 50000 * 5% = 2500, so 3 = 7500
        // Each premium is 50000 * 1% = 500
        // Need 15 invoices to cover 3 impairments (15 * 500 = 7500)
        uint256 depositAmount = 1000000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 50000;
        uint256[] memory invoiceIds = new uint256[](15);

        for (uint256 i = 0; i < 15; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            bullaFactoring.fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 91 days);

        // Impair first 3
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(insurerAddr);
            bullaFactoring.impairInvoice(invoiceIds[i]);
        }

        for (uint256 i = 0; i < 3; i++) {
            (bool isImpaired, , ) = bullaFactoring.impairmentInfo(invoiceIds[i]);
            assertTrue(isImpaired, "All invoices should be impaired");
        }
    }

    // ============================================
    // 14. Insurance premium deducted from net funded amount
    // ============================================

    function testInsurancePremiumReducesNetFunding() public {
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;

        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

        (, , , , , uint256 insurancePremium, uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);

        // Create a pool without insurance to compare
        BullaFactoringV2_2 noInsurancePool = new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, bullaFrendLend, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(0), uint16(500), uint16(5000)
        );

        vm.prank(alice);
        asset.approve(address(noInsurancePool), depositAmount);
        vm.prank(alice);
        noInsurancePool.deposit(depositAmount, alice);

        vm.prank(bob);
        uint256 invoiceId2 = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        noInsurancePool.approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, 0);

        (, , , , , uint256 noInsurancePremium, uint256 noInsuranceNetFunded) = noInsurancePool.calculateTargetFees(invoiceId2, upfrontBps);

        assertEq(noInsurancePremium, 0, "No insurance pool should have zero premium");
        assertEq(noInsuranceNetFunded - netFundedAmount, insurancePremium, "Difference in net funded should equal insurance premium");
    }

    // ============================================
    // 15. Impairment of partially paid invoice
    // ============================================

    function testImpairPartiallyPaidInvoice() public {
        // Fund extra invoices to build insurance balance
        uint256 depositAmount = 800000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;

        // Fund 5 extra invoices to build insurance
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            uint256 extraId = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(extraId, interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), extraId);
            bullaFactoring.fundInvoice(extraId, upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fund the target invoice
        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Partial payment
        uint256 partialPayment = 60000;
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), partialPayment);
        bullaClaim.payClaim(invoiceId, partialPayment);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        (, uint256 impairmentGrossGain, , , , uint256 currentPaidAmount) = bullaFactoring.previewImpair(invoiceId);

        assertEq(currentPaidAmount, partialPayment, "Paid amount should reflect partial payment");
        uint256 expectedGrossGain = Math.mulDiv(invoiceAmount - partialPayment, bullaFactoring.impairmentGrossGainBps(), 10000);
        assertEq(impairmentGrossGain, expectedGrossGain, "Gross gain based on outstanding balance after partial payment");

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        (, uint256 purchasePrice, uint256 paidAmountAtImpairment) = bullaFactoring.impairmentInfo(invoiceId);
        assertEq(purchasePrice, impairmentGrossGain, "Purchase price should match gross gain");
        assertEq(paidAmountAtImpairment, partialPayment, "Paid amount at impairment should be recorded");
    }

    // ============================================
    // 16. Recovery after partial payment at impairment
    // ============================================

    function testRecoveryAfterPartialPaymentAtImpairment() public {
        uint256 depositAmount = 800000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 100000;

        // Fund 5 extra invoices to build insurance
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            uint256 extraId = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(extraId, interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), extraId);
            bullaFactoring.fundInvoice(extraId, upfrontBps, address(0));
            vm.stopPrank();
        }

        vm.prank(bob);
        uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        // Partial payment before impairment
        uint256 partialPayment = 60000;
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), partialPayment);
        bullaClaim.payClaim(invoiceId, partialPayment);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 insuranceBalanceAfterImpair = bullaFactoring.insuranceBalance();

        // Pay the remaining amount
        uint256 remaining = invoiceAmount - partialPayment;
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), remaining);
        bullaClaim.payClaim(invoiceId, remaining);
        vm.stopPrank();

        uint256 recoveredAmount = remaining;
        (, uint256 purchasePrice, ) = bullaFactoring.impairmentInfo(invoiceId);

        if (recoveredAmount > purchasePrice) {
            uint256 excess = recoveredAmount - purchasePrice;
            uint256 investorShare = Math.mulDiv(excess, bullaFactoring.recoveryProfitRatioBps(), 10000);
            uint256 insuranceShare = recoveredAmount - investorShare;
            assertEq(
                bullaFactoring.insuranceBalance() - insuranceBalanceAfterImpair,
                insuranceShare,
                "Insurance share should be correct"
            );
        } else {
            // All goes to insurance
            assertEq(
                bullaFactoring.insuranceBalance() - insuranceBalanceAfterImpair,
                recoveredAmount,
                "All recovery should go to insurance when <= purchase price"
            );
        }
    }

    // ============================================
    // Helpers
    // ============================================

    /// @dev Fund a single invoice (insurance may be insufficient for impairment)
    function _fundSingleInvoice(uint256 invoiceAmount) internal returns (uint256 invoiceId) {
        uint256 depositAmount = invoiceAmount * 3;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        vm.prank(bob);
        invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);

        vm.prank(underwriter);
        bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    /// @dev Fund an invoice plus extra invoices to build sufficient insurance balance for impairment
    function _fundAndBuildInsurance(uint256 invoiceAmount) internal returns (uint256 targetInvoiceId) {
        // insuranceFeeBps=100 (1%), impairmentGrossGainBps=500 (5%)
        // Need at least 5 funded invoices of same size to cover 1 impairment
        // Fund 6 to have a buffer
        uint256 totalInvoices = 6;
        uint256 depositAmount = invoiceAmount * totalInvoices * 2;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        // Fund extra invoices to build insurance
        for (uint256 i = 0; i < totalInvoices - 1; i++) {
            vm.prank(bob);
            uint256 extraId = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(extraId, interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), extraId);
            bullaFactoring.fundInvoice(extraId, upfrontBps, address(0));
            vm.stopPrank();
        }

        // Fund the target invoice
        vm.prank(bob);
        targetInvoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        bullaFactoring.approveInvoice(targetInvoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), targetInvoiceId);
        bullaFactoring.fundInvoice(targetInvoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }
}
