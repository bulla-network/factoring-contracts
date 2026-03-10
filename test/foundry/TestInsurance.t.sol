// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CommonSetup.t.sol";
import {IBullaFactoringV2_2} from "../../contracts/interfaces/IBullaFactoring.sol";

contract TestInsurance is CommonSetup {
    address insurerAddr = address(0x1999);

    // ============================================
    // 1. Insurance BPS validation
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
    // 2. Insurance premium scales with outstanding balance
    // ============================================

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

        // initialInvoiceValue is already net of paidAmount (set in approveInvoice as invoiceAmount - paidAmount)
        // invoice1: initialInvoiceValue = 50000, premium = 50000 * 100 / 10000 = 500
        // invoice2: initialInvoiceValue = 25000, premium = 25000 * 100 / 10000 = 250
        assertEq(insurancePremium2, insurancePremium1 / 2, "Half-paid invoice should have half the insurance premium");
        assertGt(insurancePremium1, 0, "Full invoice premium should be non-zero");
        assertGt(insurancePremium2, 0, "Half-paid invoice premium should be non-zero");
    }
}
