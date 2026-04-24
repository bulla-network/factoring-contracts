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
            asset, invoiceAdapterBulla, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(10001), uint16(500), uint16(5000)
        );
    }

    function testConstructorRevertsImpairmentGrossGainBpsOver10000() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(100), uint16(10001), uint16(5000)
        );
    }

    function testConstructorRevertsRecoveryProfitRatioBpsOver10000() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, underwriter,
            depositPermissions, redeemPermissions, factoringPermissions,
            bullaDao, protocolFeeBps, adminFeeBps, poolName, targetYield,
            poolTokenName, poolTokenSymbol,
            insurerAddr, uint16(100), uint16(500), uint16(10001)
        );
    }

    function testConstructorRevertsImpairmentGrossGainBpsZero() public {
        vm.expectRevert();
        new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, underwriter,
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
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        _fundInvoice(invoiceId, upfrontBps, address(0));
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
        _approveInvoice(invoiceId1, interestApr, spreadBps, upfrontBps, 0);
        _approveInvoice(invoiceId2, interestApr, spreadBps, upfrontBps, 0);
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
            _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceId);
            _fundInvoice(invoiceId, upfrontBps, address(0));
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

        // Compute pool-owned withheld (target interest + admin + spread held in pool cash)
        uint256 poolOwnedWithheld;
        {
            (, , , , , , uint256 fag, uint256 fan, , , uint256 pAndI, , , ) = bullaFactoring.approvedInvoices(invoiceId);
            poolOwnedWithheld = fag - fan - (pAndI & type(uint128).max) - (pAndI >> 128);
        }

        // Get expected values from preview
        (uint256 outstandingBalance, uint256 impairmentGrossGain, uint256 adminFeeOwed, uint256 impairmentNetGain, uint256 outOfPocketCost, uint256 currentPaidAmount, uint256 spreadOwed) = bullaFactoring.previewImpair(invoiceId);

        // Verify preview values
        assertEq(outstandingBalance, 100000, "Outstanding = full invoice amount");
        assertEq(currentPaidAmount, 0, "Nothing paid");
        assertEq(impairmentGrossGain, 5000, "Gross gain = 100000 * 5% = 5000");
        assertEq(outOfPocketCost, 0, "No out-of-pocket, insurance balance 6000 >= grossGain 5000");
        assertGt(adminFeeOwed, 0, "Admin fee should be non-zero after 91 days");
        assertEq(impairmentNetGain, impairmentGrossGain - adminFeeOwed - spreadOwed, "Net gain = gross - admin - spread");

        // Execute impairment
        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        // Verify balances changed exactly as preview predicted
        assertEq(bullaFactoring.insuranceBalance(), insuranceBalanceBefore - impairmentGrossGain, "Insurance decreased by grossGain");
        // paidInvoicesGain gets both the insurance-funded net gain and the pool-owned withheld that
        // was collected at funding but never spent on admin/spread at impairment.
        assertEq(bullaFactoring.paidInvoicesGain() - paidInvoicesGainBefore, impairmentNetGain + poolOwnedWithheld, "Investor gains = netGain + poolOwnedWithheld");
        assertEq(bullaFactoring.adminFeeBalance() - adminFeeBalanceBefore, adminFeeOwed + spreadOwed, "Admin fee increased by adminFeeOwed + spreadOwed");

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
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        _fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        assertEq(bullaFactoring.insuranceBalance(), 2000, "Premium = 200000 * 1% = 2000");

        vm.warp(block.timestamp + 91 days);

        (, uint256 impairmentGrossGain, , , uint256 outOfPocketCost, , ) = bullaFactoring.previewImpair(invoiceId);
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
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        _fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), 40000);
        bullaClaim.payClaim(invoiceId, 40000);
        vm.stopPrank();

        vm.warp(block.timestamp + 91 days);

        (uint256 outstandingBalance, uint256 impairmentGrossGain, , , , uint256 currentPaidAmount, ) = bullaFactoring.previewImpair(invoiceId);

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

        (, uint256 impairmentGrossGain, , , uint256 outOfPocketCost, uint256 currentPaidAmount, ) = bullaFactoring.previewImpair(invoiceId);

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
            _approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            _fundInvoice(invoiceIds[i], upfrontBps, address(0));
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
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

        (, , , , , uint256 insurancePremium, uint256 netFundedAmount) = bullaFactoring.calculateTargetFees(invoiceId, upfrontBps);

        // Create pool with 0% insurance fee to compare
        BullaFactoringV2_2 noInsurancePool = new BullaFactoringV2_2(
            asset, invoiceAdapterBulla, underwriter,
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
        {
            IBullaFactoringV2_2.ApproveInvoiceParams[] memory approveParams = new IBullaFactoringV2_2.ApproveInvoiceParams[](1);
            approveParams[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
                invoiceId: invoiceId2,
                targetYieldBps: interestApr,
                spreadBps: spreadBps,
                upfrontBps: upfrontBps,
                initialInvoiceValueOverride: 0
            });
            noInsurancePool.approveInvoices(approveParams);
        }

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
        _approveInvoice(invoiceId, interestApr, spreadBps, upfrontBps, 0);

        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), invoiceId);
        _fundInvoice(invoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    // ============================================
    // Spread must be credited to adminFeeBalance on impairment (matches reconcileSingleInvoice).
    // Currently impairInvoice ignores spreadAmount — this test documents the expected behavior.
    // ============================================
    function testImpairmentCreditsSpreadToAdminFeeBalance() public {
        // Using CommonSetup defaults: interestApr=730, spreadBps=1000, adminFeeBps=25,
        // protocolFeeBps=25, insuranceFeeBps=100, impairmentGrossGainBps=500, upfrontBps=8000.
        // Invoice = 100_000, dueBy = +30d, warp +91d -> secondsSinceFunded = 91d.
        // calculateFees over 91d with initialInvoiceValue=100_000 (cap does not bind):
        //   targetYieldMbps  = 730_000 * 91/365                = 182_000
        //   spreadRateMbps   = 1_000_000 * 7_862_400 / 31_536_000 = 249_315
        //   adminFeeRateMbps = 25_000    * 7_862_400 / 31_536_000 = 6_232
        // (SECONDS_PER_YEAR = 31_556_952 in FeeCalculations.sol)
        //   targetYieldMbps  = 730_000 * 7_862_400 / 31_556_952   = 181_879
        //   spreadRateMbps   = 1_000_000 * 7_862_400 / 31_556_952 = 249_149
        //   adminFeeRateMbps = 25_000    * 7_862_400 / 31_556_952 = 6_228
        //   totalFeeRateMbps = 437_256
        //   totalFees        = 100_000 * 437_256 / 10_000_000     = 4_372
        //   adminFeeOwed     = 4_372 * 6_228   / 437_256          = 62
        //   interestAccrued  = 4_372 * 181_879 / 437_256          = 1_818  (discarded at impairment)
        //   spreadAccrued    = 4_372 - 62 - 1_818                 = 2_492
        uint256 expectedAdminFeeOwed = 62;
        uint256 expectedSpreadAccrued = 2_492;
        uint256 expectedImpairmentGrossGain = 5_000; // 100_000 * 5%

        uint256 invoiceId = _fundAndBuildInsurance(100_000);
        // Capture pool-owned withheld (target admin + interest + spread) at funding-time.
        // fundedAmountGross - fundedAmountNet includes protocolFee and insurancePremium which are
        // not LP-owned, so we strip them out to get the LP-owned withheld portion.
        uint256 poolOwnedWithheld;
        {
            // Packed field at position 10: upper 128 bits = insurancePremium, lower 128 = protocolFee.
            (, , , , , , uint256 _fundedAmountGross, uint256 _fundedAmountNet, , , uint256 _protocolAndInsurance, , , ) = bullaFactoring.approvedInvoices(invoiceId);
            uint256 _protocolFee = _protocolAndInsurance & type(uint128).max;
            uint256 _insurancePremium = _protocolAndInsurance >> 128;
            poolOwnedWithheld = _fundedAmountGross - _fundedAmountNet - _protocolFee - _insurancePremium;
        }
        assertGt(poolOwnedWithheld, 0, "pool-owned withheld should be non-zero when target fees > 0");

        vm.warp(block.timestamp + 91 days);

        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();
        uint256 paidInvoicesGainBefore = bullaFactoring.paidInvoicesGain();

        (, uint256 impairmentGrossGain, uint256 adminFeeOwed, uint256 impairmentNetGain, , , uint256 spreadOwed) = bullaFactoring.previewImpair(invoiceId);
        assertEq(impairmentGrossGain, expectedImpairmentGrossGain, "grossGain = invoiceAmount * 5%");
        assertEq(adminFeeOwed, expectedAdminFeeOwed, "adminFeeOwed = 62");
        assertEq(spreadOwed, expectedSpreadAccrued, "spreadOwed = 2492");
        assertEq(
            impairmentNetGain,
            expectedImpairmentGrossGain - expectedAdminFeeOwed - expectedSpreadAccrued,
            "impairmentNetGain = grossGain - admin - spread"
        );

        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 adminFeeBalanceDelta = bullaFactoring.adminFeeBalance() - adminFeeBalanceBefore;
        uint256 paidInvoicesGainDelta = bullaFactoring.paidInvoicesGain() - paidInvoicesGainBefore;

        // adminFeeBalance captures BOTH admin fee and spread, matching
        // incrementProfitAndFeeBalances() in the normal reconciliation path.
        assertEq(
            adminFeeBalanceDelta,
            expectedAdminFeeOwed + expectedSpreadAccrued,
            "adminFeeBalance must include accrued spread, not just admin fee"
        );
        // paidInvoicesGain = impairmentNetGain (from gross gain) + pool-owned withheld (target fees
        // collected at funding that weren't spent on admin/spread payouts).
        assertEq(
            paidInvoicesGainDelta,
            (expectedImpairmentGrossGain - expectedAdminFeeOwed - expectedSpreadAccrued) + poolOwnedWithheld,
            "paidInvoicesGain = impairmentNetGain + poolOwnedWithheld"
        );
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
            _approveInvoice(extraId, interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), extraId);
            _fundInvoice(extraId, upfrontBps, address(0));
            vm.stopPrank();
        }

        vm.prank(bob);
        targetInvoiceId = createClaim(bob, alice, invoiceAmount, dueBy);
        vm.prank(underwriter);
        _approveInvoice(targetInvoiceId, interestApr, spreadBps, upfrontBps, 0);
        vm.startPrank(bob);
        bullaClaim.approve(address(bullaFactoring), targetInvoiceId);
        _fundInvoice(targetInvoiceId, upfrontBps, address(0));
        vm.stopPrank();
    }

    // ============================================
    // Kickback at reconciliation must exclude the insurance premium.
    // The premium is withheld from the gross funded amount at funding and earmarked
    // into insuranceBalance — it is not pool cash that can be returned to the factorer.
    // Without the fix, the cap on kickback only subtracted protocolFee, so the premium
    // silently flowed back to the factorer as kickback (LP-funded gift).
    // ============================================
    function testReconciliationKickbackExcludesInsurancePremium() public {
        // CommonSetup defaults: interestApr=730, spreadBps=1000, adminFeeBps=25,
        //   protocolFeeBps=25, insuranceFeeBps=100, upfrontBps=8000, dueBy=+30d.
        // Invoice = 100_000, paid in full exactly at dueBy (secondsOfInterest = 30d).
        //
        // Funding-time fees (per FeeCalculations math, SECONDS_PER_YEAR = 31_556_952):
        //   protocolFee      = 100_000 * 25/10_000               = 250
        //   insurancePremium = 100_000 * 100/10_000              = 1_000
        //   targetYieldMbps  = 730_000  * 2_592_000 / 31_556_952 = 59_961
        //   spreadRateMbps   = 1_000_000 * 2_592_000 / 31_556_952 = 82_138
        //   adminFeeRateMbps = 25_000   * 2_592_000 / 31_556_952 =  2_053
        //   totalFeeRateMbps = 144_152
        //   totalFees_calc   = 100_000 * 144_152 / 10_000_000    = 1_441
        //   adminFee         = 1_441 * 2_053  / 144_152          =     20
        //   interest         = 1_441 * 59_961 / 144_152          =    599
        //   spreadAmount     = 1_441 - 20 - 599                  =    822
        //   totalFees        = 20 + 599 + 822 + 250 + 1_000      =  2_691
        //   fundedAmountGross= 100_000 * 80%                     = 80_000
        //   fundedAmountNet  = 80_000 - 2_691                    = 77_309
        // Expected reconciliation kickback (with fix) = invoiceAmount - fundedAmountGross = 20_000.
        // Without fix, kickback would be 21_000 — the extra 1_000 is the insurance premium
        // erroneously refunded to the factorer.
        uint256 invoiceAmount = 100_000;
        uint256 expectedFundedNet = 77_309;
        uint256 expectedKickback = 20_000;
        uint256 expectedInsurancePremium = 1_000;
        uint256 expectedProtocolFee = 250;
        uint256 expectedAdminPlusSpread = 20 + 822;
        uint256 expectedInterest = 599;

        uint256 bobBalanceBeforeFunding = asset.balanceOf(bob);
        uint256 invoiceId = _fundSingleInvoice(invoiceAmount);

        // Bob received fundedAmountNet at funding.
        uint256 bobReceivedAtFunding = asset.balanceOf(bob) - bobBalanceBeforeFunding;
        assertEq(bobReceivedAtFunding, expectedFundedNet, "fundedAmountNet matches expected");
        assertEq(
            bullaFactoring.insuranceBalance(),
            expectedInsurancePremium,
            "insuranceBalance holds funding-time premium"
        );

        uint256 insuranceBalanceBefore = bullaFactoring.insuranceBalance();
        uint256 protocolFeeBalanceBefore = bullaFactoring.protocolFeeBalance();
        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();
        uint256 paidInvoicesGainBefore = bullaFactoring.paidInvoicesGain();
        uint256 bobBalanceBeforePayment = asset.balanceOf(bob);

        // Pay invoice in full exactly at dueBy. Triggers reconcileSingleInvoice via the
        // paid-callback registered in CommonSetup.
        vm.warp(dueBy);
        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(invoiceId, invoiceAmount);
        vm.stopPrank();

        // Kickback delivered to bob = invoice payment minus fundedAmountGross.
        uint256 bobKickback = asset.balanceOf(bob) - bobBalanceBeforePayment;
        assertEq(
            bobKickback,
            expectedKickback,
            "kickback excludes insurance premium (would be 21_000 with bug)"
        );

        // Insurance balance unchanged at reconciliation — premium stays earmarked for insurer.
        assertEq(
            bullaFactoring.insuranceBalance() - insuranceBalanceBefore,
            0,
            "insuranceBalance unchanged at reconciliation"
        );
        // Protocol fee balance unchanged at reconciliation (already collected at funding).
        assertEq(
            bullaFactoring.protocolFeeBalance() - protocolFeeBalanceBefore,
            0,
            "protocolFeeBalance unchanged at reconciliation"
        );
        // Admin + spread credited to adminFeeBalance, interest credited to paidInvoicesGain.
        assertEq(
            bullaFactoring.adminFeeBalance() - adminFeeBalanceBefore,
            expectedAdminPlusSpread,
            "adminFeeBalance += admin + spread"
        );
        assertEq(
            bullaFactoring.paidInvoicesGain() - paidInvoicesGainBefore,
            expectedInterest,
            "paidInvoicesGain += interest"
        );

        // Conservation: bob's net P&L on the invoice equals -totalFees (incl. insurance).
        uint256 bobTotalReceived = bobReceivedAtFunding + bobKickback;
        assertEq(
            invoiceAmount - bobTotalReceived,
            expectedProtocolFee + expectedInsurancePremium + expectedAdminPlusSpread + expectedInterest,
            "bob effectively paid all fees including the insurance premium"
        );
    }

    // ============================================
    // Full impairment lifecycle: fund -> impair -> repay -> reconcile
    //
    // Uses round numbers to verify capital account and price per share
    // at each step. The test documents the expected correct behavior:
    //
    // 1. After impairment: capital account should DECREASE (loss recognition)
    // 2. After full repayment + reconcile: capital account should recover
    //    (loss reversal + recovery profit split)
    //
    // CommonSetup defaults used:
    //   interestApr=730, spreadBps=1000, adminFeeBps=25, protocolFeeBps=25
    //   insuranceFeeBps=100 (1%), impairmentGrossGainBps=500 (5%)
    //   recoveryProfitRatioBps=5000 (50%), upfrontBps=8000 (80%)
    //   dueBy=+30d, impairmentGracePeriod=60d
    // ============================================

    function testImpairmentCapitalAccountAndPricePerShare() public {
        // ---- Setup: clean round numbers ----
        uint256 depositAmount = 1_200_000;
        uint256 invoiceAmount = 100_000;

        vm.prank(alice);
        bullaFactoring.deposit(depositAmount, alice);

        uint256 sharesAfterDeposit = bullaFactoring.balanceOf(alice);
        assertEq(sharesAfterDeposit, depositAmount, "1:1 share ratio on first deposit");

        // ---- Fund 6 invoices to build insurance balance ----
        // Each: insurancePremium = 100,000 * 1% = 1,000 => total insurance = 6,000
        // impairmentGrossGain = 100,000 * 5% = 5,000 => insurance sufficient
        uint256[] memory invoiceIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(bob);
            invoiceIds[i] = createClaim(bob, alice, invoiceAmount, dueBy);
            vm.prank(underwriter);
            _approveInvoice(invoiceIds[i], interestApr, spreadBps, upfrontBps, 0);
            vm.startPrank(bob);
            bullaClaim.approve(address(bullaFactoring), invoiceIds[i]);
            _fundInvoice(invoiceIds[i], upfrontBps, address(0));
            vm.stopPrank();
        }

        assertEq(bullaFactoring.insuranceBalance(), 6_000, "6 invoices * 1,000 premium = 6,000");

        // ---- Snapshot state before impairment ----
        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();
        uint256 pricePerShareBefore = bullaFactoring.pricePerShare();

        // capitalAccount = totalDeposits + paidInvoicesGain - totalWithdrawals = 1,200,000 + 0 - 0
        assertEq(capitalAccountBefore, depositAmount, "Capital account equals deposit before any gains/losses");

        // ---- Warp past impairment date (dueBy + gracePeriod + 1 day) ----
        vm.warp(block.timestamp + 91 days);

        uint256 targetInvoiceId = invoiceIds[5];

        // Get the funded amounts for this invoice
        uint256 fundedAmountGross;
        uint256 fundedAmountNet;
        {
            (, , , , , , uint256 fag, uint256 fan, , , , , , ) = bullaFactoring.approvedInvoices(targetInvoiceId);
            fundedAmountGross = fag;
            fundedAmountNet = fan;
        }

        // Preview impairment
        (
            uint256 outstandingBalance,
            uint256 impairmentGrossGain,
            ,
            ,
            uint256 outOfPocketCost,
            ,
        ) = bullaFactoring.previewImpair(targetInvoiceId);

        assertEq(outstandingBalance, 100_000, "Full invoice outstanding");
        assertEq(impairmentGrossGain, 5_000, "5% of 100,000");
        assertEq(outOfPocketCost, 0, "Insurance sufficient");

        // ---- Execute impairment ----
        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(targetInvoiceId);

        // ---- PHASE 1: Verify state after impairment ----
        uint256 capitalAccountAfterImpair = bullaFactoring.calculateCapitalAccount();
        uint256 pricePerShareAfterImpair = bullaFactoring.pricePerShare();

        emit log_named_uint("depositAmount", depositAmount);
        emit log_named_uint("fundedAmountGross", fundedAmountGross);
        emit log_named_uint("fundedAmountNet", fundedAmountNet);
        emit log_named_uint("impairmentGrossGain (insurance coverage)", impairmentGrossGain);
        emit log_named_uint("capitalAccountBefore", capitalAccountBefore);
        emit log_named_uint("capitalAccountAfterImpair", capitalAccountAfterImpair);
        emit log_named_uint("pricePerShareBefore", pricePerShareBefore);
        emit log_named_uint("pricePerShareAfterImpair", pricePerShareAfterImpair);
        emit log_named_uint("paidInvoicesGain after impair", bullaFactoring.paidInvoicesGain());

        // The pool funded this invoice and will not get paid back (it's impaired).
        // Insurance covers 5,000 of the 100,000 outstanding.
        // Capital account must DECREASE to reflect the unrealized loss.
        assertTrue(
            capitalAccountAfterImpair < capitalAccountBefore,
            "BUG: Capital account should DECREASE after impairment (loss), but it INCREASED"
        );

        // Price per share must also decrease
        assertTrue(
            pricePerShareAfterImpair < pricePerShareBefore,
            "BUG: Price per share should DECREASE after impairment (loss), but it INCREASED"
        );

        // ---- PHASE 2: Full repayment of the impaired invoice ----
        // The debtor pays the full 100,000. This triggers reconcileSingleInvoice
        // via the paid-callback.
        //
        // Recovery math (current code):
        //   recoveredAmount = paidAmount - paidAmountAtImpairment = 100,000 - 0 = 100,000
        //   excess = recoveredAmount - purchasePrice = 100,000 - 5,000 = 95,000
        //   investorShare = excess * 50% = 47,500
        //   insuranceShare = recoveredAmount - investorShare = 52,500
        //   paidInvoicesGain += investorShare (47,500)
        //   insuranceBalance += insuranceShare (52,500)

        uint256 capitalAccountBeforeRepay = bullaFactoring.calculateCapitalAccount();
        uint256 paidInvoicesGainBeforeRepay = bullaFactoring.paidInvoicesGain();

        vm.startPrank(alice);
        asset.approve(address(bullaClaim), invoiceAmount);
        bullaClaim.payClaim(targetInvoiceId, invoiceAmount);
        vm.stopPrank();

        uint256 capitalAccountAfterRepay = bullaFactoring.calculateCapitalAccount();
        uint256 pricePerShareAfterRepay = bullaFactoring.pricePerShare();
        uint256 paidInvoicesGainAfterRepay = bullaFactoring.paidInvoicesGain();

        emit log_named_uint("capitalAccountAfterRepay", capitalAccountAfterRepay);
        emit log_named_uint("pricePerShareAfterRepay", pricePerShareAfterRepay);
        emit log_named_uint("paidInvoicesGain delta at reconcile", paidInvoicesGainAfterRepay - paidInvoicesGainBeforeRepay);

        // After full repayment, the loss is reversed and the LP gets a profit share.
        // The capital account should be HIGHER than before repayment.
        assertTrue(
            capitalAccountAfterRepay > capitalAccountBeforeRepay,
            "Capital account should increase after full repayment of impaired invoice"
        );

        // After full repayment, LPs should have recovered most of their capital.
        // The pool originally funded 80,000 gross. The debtor repaid 100,000.
        // Of the 100,000 recovered:
        //   - Insurance gets back purchasePrice (5,000) + 50% of excess (47,500) = 52,500
        //   - LPs get 50% of excess = 47,500
        //
        // Net LP position over the full lifecycle (impair + recover):
        //   At impairment: loss recognized (capital account decreases)
        //   At recovery: gain of investorShare = 47,500
        //   Net: LPs should be ahead of where they started (they funded 80,000
        //         and get back the original capital + 47,500 profit share of recovery)
        //
        // The capital account after full recovery should be HIGHER than before impairment,
        // because the recovery profit (investorShare) exceeds any residual accounting cost.
        assertTrue(
            capitalAccountAfterRepay > capitalAccountBefore,
            "After full recovery, capital account should exceed pre-impairment level"
        );

        emit log_named_uint("Final capitalAccount", capitalAccountAfterRepay);
        emit log_named_uint("Final pricePerShare", pricePerShareAfterRepay);
        emit log_named_uint("Final paidInvoicesGain", paidInvoicesGainAfterRepay);
    }

    // ============================================
    // Impairment when accrued fees exceed impairmentGrossGain
    //
    // When an invoice sits long enough, accrued admin + spread fees
    // can exceed the impairmentGrossGain (5% of outstanding). In that
    // case impairmentNetGain = 0, but the full fees are still credited
    // to adminFeeBalance.
    //
    // The concern: the excess fees beyond what insurance covers are
    // effectively paid from poolOwnedWithheld (LP capital), but
    // paidInvoicesGain still credits the full poolOwnedWithheld.
    // The admin fee should be deducted from the LP credit if it
    // exceeds what insurance can cover.
    //
    // CommonSetup: spreadBps=1000 (10%/yr), adminFeeBps=25 (0.25%/yr),
    //   impairmentGrossGainBps=500 (5%)
    // At ~200 days, spread alone ~= 10% * 200/365 ~= 5.5% > grossGain 5%
    // ============================================

    function testImpairmentFeesExceedGrossGain() public {
        uint256 invoiceAmount = 100_000;
        uint256 invoiceId = _fundAndBuildInsurance(invoiceAmount);

        // Record state before impairment
        uint256 capitalAccountBefore = bullaFactoring.calculateCapitalAccount();
        uint256 paidInvoicesGainBefore = bullaFactoring.paidInvoicesGain();
        uint256 adminFeeBalanceBefore = bullaFactoring.adminFeeBalance();

        // Get the funded amounts and pool-owned withheld for this invoice
        uint256 fundedAmountGross;
        uint256 fundedAmountNet;
        uint256 poolOwnedWithheld;
        {
            (, , , , , , uint256 fag, uint256 fan, , , uint256 pAndI, , , ) = bullaFactoring.approvedInvoices(invoiceId);
            fundedAmountGross = fag;
            fundedAmountNet = fan;
            poolOwnedWithheld = fag - fan - (pAndI & type(uint128).max) - (pAndI >> 128);
        }

        // Warp to 200 days so accrued fees exceed impairmentGrossGain
        // dueBy = +30d, impairmentGracePeriod = 60d, so 200d is well past
        vm.warp(block.timestamp + 200 days);

        // Preview to verify fees > grossGain
        (
            uint256 outstandingBalance,
            uint256 impairmentGrossGain,
            uint256 adminFeeOwed,
            uint256 impairmentNetGain,
            ,
            ,
            uint256 spreadOwed
        ) = bullaFactoring.previewImpair(invoiceId);

        uint256 totalFeesOwed = adminFeeOwed + spreadOwed;

        emit log_named_uint("outstandingBalance", outstandingBalance);
        emit log_named_uint("impairmentGrossGain", impairmentGrossGain);
        emit log_named_uint("adminFeeOwed", adminFeeOwed);
        emit log_named_uint("spreadOwed", spreadOwed);
        emit log_named_uint("totalFeesOwed", totalFeesOwed);
        emit log_named_uint("impairmentNetGain", impairmentNetGain);
        emit log_named_uint("fundedAmountGross", fundedAmountGross);
        emit log_named_uint("fundedAmountNet", fundedAmountNet);
        emit log_named_uint("poolOwnedWithheld", poolOwnedWithheld);

        // Confirm fees exceed grossGain => impairmentNetGain = 0
        assertTrue(totalFeesOwed > impairmentGrossGain, "Fees must exceed grossGain for this test");
        assertEq(impairmentNetGain, 0, "impairmentNetGain should be 0 when fees > grossGain");

        // The fee overage beyond what insurance covers
        uint256 feeOverage = totalFeesOwed - impairmentGrossGain;
        emit log_named_uint("feeOverage (fees exceeding insurance)", feeOverage);

        // ---- Execute impairment ----
        vm.prank(insurerAddr);
        bullaFactoring.impairInvoice(invoiceId);

        uint256 capitalAccountAfter = bullaFactoring.calculateCapitalAccount();
        uint256 paidInvoicesGainAfter = bullaFactoring.paidInvoicesGain();
        uint256 adminFeeBalanceAfter = bullaFactoring.adminFeeBalance();

        uint256 paidInvoicesGainDelta = paidInvoicesGainAfter - paidInvoicesGainBefore;
        uint256 adminFeeBalanceDelta = adminFeeBalanceAfter - adminFeeBalanceBefore;

        emit log_named_uint("capitalAccountBefore", capitalAccountBefore);
        emit log_named_uint("capitalAccountAfter", capitalAccountAfter);
        emit log_named_uint("paidInvoicesGain delta", paidInvoicesGainDelta);
        emit log_named_uint("adminFeeBalance delta", adminFeeBalanceDelta);

        // Current behavior: adminFeeBalance gets the FULL fee amount (adminFeeOwed + spreadOwed),
        // even though insurance only covers impairmentGrossGain. The excess is silently taken
        // from pool cash (LP capital via poolOwnedWithheld).
        //
        // paidInvoicesGain gets: impairmentNetGain (0) + poolOwnedWithheld (1,441)
        // But poolOwnedWithheld should be reduced by the fee overage, because those
        // withheld fees are being consumed by the admin/spread fees.
        //
        // Expected correct behavior:
        //   adminFeeBalance += min(totalFeesOwed, impairmentGrossGain + poolOwnedWithheld)
        //   paidInvoicesGain += max(0, poolOwnedWithheld - feeOverage)
        //
        // Or alternatively: the admin fee should be capped at impairmentGrossGain,
        // and the remainder should NOT be charged to LP capital.

        // The fee overage comes out of LP pocket (poolOwnedWithheld).
        // paidInvoicesGain should credit LPs only what's left after the fee overage.
        uint256 expectedLPCredit = poolOwnedWithheld > feeOverage ? poolOwnedWithheld - feeOverage : 0;

        emit log_named_uint("expected LP credit (poolOwnedWithheld - feeOverage)", expectedLPCredit);
        emit log_named_uint("actual LP credit (paidInvoicesGain delta)", paidInvoicesGainDelta);

        // This assertion checks that the LP credit accounts for the fee overage.
        // If this FAILS, it means LPs are being credited the full poolOwnedWithheld
        // even though part of it was consumed by admin/spread fees exceeding insurance.
        assertEq(
            paidInvoicesGainDelta,
            expectedLPCredit,
            "LP credit should be reduced by fee overage (fees exceeding insurance coverage)"
        );

        // Capital account should still decrease after impairment
        assertTrue(
            capitalAccountAfter < capitalAccountBefore,
            "Capital account should decrease after impairment"
        );
    }
}
