// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IBullaFactoringV2_2} from "../../contracts/interfaces/IBullaFactoring.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TestInsurance is CommonSetup {
    address insurerAddr = address(0x1999);

    // CommonSetup params:
    // insuranceFeeBps = 100 (1%), impairmentGrossGainBps = 500 (5%), recoveryProfitRatioBps = 5000 (50%)
    // adminFeeBps = 25 (0.25%), protocolFeeBps = 25 (0.25%)
    // dueBy = block.timestamp + 30 days, impairmentGracePeriod = 60 days
    // Need vm.warp(block.timestamp + 91 days) to pass grace period

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

        // invoiceAmount = 100000, insuranceFeeBps = 100 (1%)
        // expected premium = 100000 * 100 / 10000 = 1000
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

        assertEq(bullaFactoring.insuranceBalance() - insuranceBalanceBefore, 1000, "Premium should be 1% of 100000 = 1000");
    }

    function testInsurancePremiumHalfPaidInvoice() public {
        uint256 depositAmount = 200000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 invoiceAmount = 50000;

        // Invoice 1: fully unpaid → premium on full 50000
        vm.prank(bob);
        uint256 invoiceId1 = createClaim(bob, alice, invoiceAmount, dueBy);

        // Invoice 2: half paid → premium on remaining 25000
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

        // 50000 * 1% = 500, 25000 * 1% = 250
        assertEq(insurancePremium1, 500, "Full invoice premium = 500");
        assertEq(insurancePremium2, 250, "Half-paid invoice premium = 250");
    }

    function testInsuranceBalanceAccumulatesAcrossMultipleFundings() public {
        uint256 depositAmount = 500000;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        // Fund 3 invoices of 50000 each. Each premium = 50000 * 1% = 500
        // Total expected = 1500
        uint256 invoiceAmount = 50000;

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(bob);
            uint256 invoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            bullaFactoring.approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            bullaFactoring.fundInvoice(invoiceId, upfrontBps, address(0));
            vm.stopPrank();
        }

        assertEq(bullaFactoring.insuranceBalance(), 1500, "3 x 500 premium = 1500");
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
        // Fund a 100000 invoice → premium = 1000
        _fundSingleInvoice(100000);

        assertEq(bullaFactoring.insuranceBalance(), 1000, "Insurance balance should be 1000 after funding");

        uint256 insurerBalanceBefore = asset.balanceOf(insurerAddr);

        vm.prank(insurerAddr);
        bullaFactoring.withdrawInsuranceBalance();

        assertEq(bullaFactoring.insuranceBalance(), 0, "Insurance balance should be zero after withdrawal");
        assertEq(asset.balanceOf(insurerAddr) - insurerBalanceBefore, 1000, "Insurer should receive 1000");
    }

    function testWithdrawInsuranceBalanceZero() public {
        vm.prank(insurerAddr);
        bullaFactoring.withdrawInsuranceBalance();
        assertEq(bullaFactoring.insuranceBalance(), 0);
    }

    // ============================================
    // 5. previewImpair then impair, verify all balances
    // ============================================

    function testPreviewImpairThenImpairVerifyBalances() public {
        // Fund 6 invoices of 100000 to build insurance: 6 * 1000 = 6000
        // impairmentGrossGain for 100000 = 100000 * 5% = 5000
        // outOfPocketCost = 0 since 6000 >= 5000
        uint256 invoiceId = _fundAndBuildInsurance(100000);
        vm.warp(block.timestamp + 91 days);

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();
        uint256 paidInvoicesGainBefore = bullaFactoring.paidInvoicesGain();
        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();

        // Get expected values from preview
        (uint256 outstandingBalance, uint256 impairmentGrossGain, uint256 adminFeeOwed, uint256 impairmentNetGain, uint256 outOfPocketCost, uint256 currentPaidAmount) = bullaFactoring.previewImpair(invoiceId);

        // Verify preview values
        assertEq(outstandingBalance, 100000, "Outstanding = full invoice amount");
        assertEq(currentPaidAmount, 0, "Nothing paid");
        assertEq(impairmentGrossGain, 5000, "Gross gain = 100000 * 5% = 5000");
        assertEq(outOfPocketCost, 0, "No out-of-pocket, insurance balance 6000 >= grossGain 5000");
        assertGt(adminFeeOwed, 0, "Admin fee should be non-zero after 91 days");
        assertEq(impairmentNetGain, impairmentGrossGain - adminFeeOwed, "Net gain = gross - admin fee");

        // Execute impairment
        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        // Verify balances changed exactly as preview predicted
        assertEq(bullaFactoring.insuranceBalance(), insuranceBalanceBefore - impairmentGrossGain, "Insurance decreased by grossGain");
        assertEq(bullaFactoring.paidInvoicesGain() - paidInvoicesGainBefore, impairmentNetGain, "Investor gains increased by netGain");
        assertEq(bullaFactoring.adminFeeBalance() - adminFeeBalanceBefore, adminFeeOwed, "Admin fee increased by adminFeeOwed");

        // Verify impairment info
        (bool isImpaired, uint256 purchasePrice, uint256 paidAmountAtImpairment) = bullaFactoring.impairmentInfo(invoiceId);
        assertTrue(isImpaired, "Invoice should be impaired");
        assertEq(purchasePrice, 5000, "Purchase price = grossGain = 5000");
        assertEq(paidAmountAtImpairment, 0, "No payment at impairment");
    }

    // ============================================
    // 6. Impairment with insufficient insurance (out-of-pocket)
    // ============================================

    function testImpairInvoiceWithInsufficientInsurance() public {
        // Single 200000 invoice: premium = 200000 * 1% = 2000
        // impairmentGrossGain = 200000 * 5% = 10000
        // outOfPocketCost = 10000 - 2000 = 8000
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

        assertEq(bullaFactoring.insuranceBalance(), 2000, "Premium = 200000 * 1% = 2000");

        vm.warp(block.timestamp + 91 days);

        (, uint256 impairmentGrossGain, , , uint256 outOfPocketCost, ) = bullaFactoring.previewImpair(invoiceId);
        assertEq(impairmentGrossGain, 10000, "Gross gain = 200000 * 5% = 10000");
        assertEq(outOfPocketCost, 8000, "Out-of-pocket = 10000 - 2000 = 8000");

        // Give insurer tokens for out-of-pocket
        asset.mint(insurerAddr, 8000);
        vm.prank(insurerAddr);
        asset.approve(address(bullaFactoring), 8000);

        uint256 insurerBalanceBefore = asset.balanceOf(insurerAddr);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.insuranceBalance(), 0, "Insurance fully depleted");
        assertEq(insurerBalanceBefore - asset.balanceOf(insurerAddr), 8000, "Insurer paid 8000 out-of-pocket");

        (bool isImpaired, , ) = bullaFactoring.impairmentInfo(invoiceId);
        assertTrue(isImpaired, "Invoice should be impaired");
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
    // 8. Recovery: full payment after impairment, verify profit split
    // ============================================

    function testRecoveryProfitSplitFullPayment() public {
        // Setup: 100000 invoice, fully unpaid at impairment
        // impairmentGrossGain (= purchasePrice) = 100000 * 5% = 5000
        // After full payment: recoveredAmount = 100000 - 0 = 100000
        // excess = 100000 - 5000 = 95000
        // investorShare = 95000 * 50% = 47500
        // insuranceShare = 100000 - 47500 = 52500
        uint256 invoiceAmount = 100000;
        uint256 invoiceId = _fundAndBuildInsurance(invoiceAmount);
        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 insuranceBalanceAfterImpair = bullaFactoring.insuranceBalance();
        uint256 paidInvoicesGainAfterImpair = bullaFactoring.paidInvoicesGain();

        // Pay the full invoice
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // recoveredAmount = 100000, purchasePrice = 5000
        // excess = 95000, investorShare = 47500, insuranceShare = 52500
        uint256 insuranceGain = bullaFactoring.insuranceBalance() - insuranceBalanceAfterImpair;
        uint256 investorGain = bullaFactoring.paidInvoicesGain() - paidInvoicesGainAfterImpair;

        assertEq(insuranceGain, 52500, "Insurance recovers 52500");
        assertEq(investorGain, 47500, "Investors receive 47500");
    }

    // ============================================
    // 9. previewImpair: partially paid invoice
    // ============================================

    function testPreviewImpairPartiallyPaidInvoice() public {
        // 100000 invoice, 40000 paid before impairment
        // outstandingBalance = 60000
        // impairmentGrossGain = 60000 * 5% = 3000
        // currentPaidAmount = 40000
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

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 40000);
        bullaClaim.payClaim(invoiceId, 40000);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        (uint256 outstandingBalance, uint256 impairmentGrossGain, , , , uint256 currentPaidAmount) = bullaFactoring.previewImpair(invoiceId);

        assertEq(currentPaidAmount, 40000, "Paid amount = 40000");
        assertEq(outstandingBalance, 60000, "Outstanding = 100000 - 40000 = 60000");
        assertEq(impairmentGrossGain, 3000, "Gross gain = 60000 * 5% = 3000");
    }

    // ============================================
    // 10. Impairment of partially paid invoice with balance verification
    // ============================================

    function testImpairPartiallyPaidInvoiceBalances() public {
        // 100000 invoice, 60000 paid. outstanding = 40000
        // grossGain = 40000 * 5% = 2000, purchasePrice = 2000
        // Need insurance balance >= 2000, 6 invoices of 100000 → 6000 insurance
        uint256 invoiceId = _fundAndBuildInsurance(100000);

        // Partial payment of 60000
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 60000);
        bullaClaim.payClaim(invoiceId, 60000);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();

        (, uint256 impairmentGrossGain, , , uint256 outOfPocketCost, uint256 currentPaidAmount) = bullaFactoring.previewImpair(invoiceId);

        assertEq(currentPaidAmount, 60000, "Paid amount = 60000");
        assertEq(impairmentGrossGain, 2000, "Gross gain = 40000 * 5% = 2000");
        assertEq(outOfPocketCost, 0, "No out-of-pocket, insurance 6000 >= 2000");

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.insuranceBalance(), insuranceBalanceBefore - 2000, "Insurance decreased by 2000");

        (, uint256 purchasePrice, uint256 paidAmountAtImpairment) = bullaFactoring.impairmentInfo(invoiceId);
        assertEq(purchasePrice, 2000, "Purchase price = 2000");
        assertEq(paidAmountAtImpairment, 60000, "Paid at impairment = 60000");
    }

    // ============================================
    // 11. Recovery after partial payment at impairment
    // ============================================

    function testRecoveryAfterPartialPaymentAtImpairment() public {
        // 100000 invoice, 60000 paid at impairment
        // purchasePrice = (100000 - 60000) * 5% = 2000
        // After remaining 40000 paid: recoveredAmount = 40000
        // excess = 40000 - 2000 = 38000
        // investorShare = 38000 * 50% = 19000
        // insuranceShare = 40000 - 19000 = 21000
        uint256 invoiceId = _fundAndBuildInsurance(100000);

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 60000);
        bullaClaim.payClaim(invoiceId, 60000);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 insuranceBalanceAfterImpair = bullaFactoring.insuranceBalance();
        uint256 paidInvoicesGainAfterImpair = bullaFactoring.paidInvoicesGain();

        // Pay remaining 40000
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 40000);
        bullaClaim.payClaim(invoiceId, 40000);
        vm.stopPrank();

        uint256 insuranceGain = bullaFactoring.insuranceBalance() - insuranceBalanceAfterImpair;
        uint256 investorGain = bullaFactoring.paidInvoicesGain() - paidInvoicesGainAfterImpair;

        assertEq(insuranceGain, 21000, "Insurance recovers 21000");
        assertEq(investorGain, 19000, "Investors receive 19000");
    }

    // ============================================
    // 12. Impairment records to impairedInvoices array
    // ============================================

    function testImpairmentAddsToImpairedInvoicesArray() public {
        uint256 invoiceId = _fundAndBuildInsurance(100000);
        vm.warp(block.timestamp + 91 days);

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        assertEq(bullaFactoring.impairedInvoices(0), invoiceId, "Impaired invoice should be in array");
    }

    // ============================================
    // 13. Recovery removes from impairedInvoices array
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

        vm.expectRevert();
        bullaFactoring.impairedInvoices(0);
    }

    // ============================================
    // 14. Multiple impairments
    // ============================================

    function testMultipleImpairments() public {
        // 15 invoices of 50000: premiums = 15 * 500 = 7500
        // 3 impairments: 3 * 50000 * 5% = 7500
        // Insurance balance just covers all 3
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

        assertEq(bullaFactoring.insuranceBalance(), 7500, "15 * 500 = 7500");

        vm.warp(block.timestamp + 91 days);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(insurerAddr);
            bullaFactoring.impairInvoice(invoiceIds[i]);
        }

        // 7500 - 3 * 2500 = 0
        assertEq(bullaFactoring.insuranceBalance(), 0, "All insurance consumed by 3 impairments");

        for (uint256 i = 0; i < 3; i++) {
            (bool isImpaired, , ) = bullaFactoring.impairmentInfo(invoiceIds[i]);
            assertTrue(isImpaired, "Invoice should be impaired");
        }
    }

    // ============================================
    // 15. Insurance premium reduces net funded amount
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

        // Create pool with 0% insurance fee to compare
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

        assertEq(insurancePremium, 1000, "Insurance premium = 100000 * 1% = 1000");
        assertEq(noInsurancePremium, 0, "No insurance premium");
        assertEq(noInsuranceNetFunded - netFundedAmount, 1000, "Net funded differs by exactly the premium");
    }

    // ============================================
    // Helpers
    // ============================================

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

    function _fundAndBuildInsurance(uint256 invoiceAmount) internal returns (uint256 targetInvoiceId) {
        // insuranceFeeBps=100 (1%), impairmentGrossGainBps=500 (5%)
        // 6 invoices: insurance = 6 * invoiceAmount * 1% = 6% of invoiceAmount
        // grossGain = invoiceAmount * 5% → sufficient since 6% > 5%
        uint256 totalInvoices = 6;
        uint256 depositAmount = invoiceAmount * totalInvoices * 2;
        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

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
