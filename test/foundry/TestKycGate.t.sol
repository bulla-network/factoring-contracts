// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { ManualBullaKycIssuer } from 'contracts/ManualBullaKycIssuer.sol';
import { BullaKycGate } from 'contracts/BullaKycGate.sol';
import { IBullaKycIssuer } from 'contracts/interfaces/IBullaKycIssuer.sol';
import { BullaFactoringV2_2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';

// ============ Unit Tests: ManualBullaKycIssuer ============

contract TestManualBullaKycIssuer is Test {
    ManualBullaKycIssuer public issuer;
    address nonOwner = address(0xBEEF);
    address user = address(0xCAFE);

    function setUp() public {
        issuer = new ManualBullaKycIssuer();
    }

    function testApproveSetIsKycedToTrue() public {
        assertFalse(issuer.isKyced(user));
        issuer.approve(user);
        assertTrue(issuer.isKyced(user));
    }

    function testRevokeSetIsKycedToFalse() public {
        issuer.approve(user);
        assertTrue(issuer.isKyced(user));
        issuer.revoke(user);
        assertFalse(issuer.isKyced(user));
    }

    function testNonOwnerCannotApprove() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        issuer.approve(user);
        vm.stopPrank();
    }

    function testNonOwnerCannotRevoke() public {
        issuer.approve(user);
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        issuer.revoke(user);
        vm.stopPrank();
    }
}

// ============ Unit Tests: BullaKycGate ============

contract TestBullaKycGate is Test {
    BullaKycGate public gate;
    ManualBullaKycIssuer public issuer1;
    ManualBullaKycIssuer public issuer2;
    address nonOwner = address(0xBEEF);
    address user = address(0xCAFE);

    function setUp() public {
        gate = new BullaKycGate();
        issuer1 = new ManualBullaKycIssuer();
        issuer2 = new ManualBullaKycIssuer();
    }

    function testIsAllowedReturnsFalseWithNoIssuers() public view {
        assertFalse(gate.isAllowed(user));
    }

    function testIsAllowedReturnsTrueWhenOneIssuerApproves() public {
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        issuer1.approve(user);
        assertTrue(gate.isAllowed(user));
    }

    function testIsAllowedReturnsTrueWithMultipleIssuersOrLogic() public {
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        gate.addIssuer(IBullaKycIssuer(address(issuer2)));
        // Only issuer2 approves the user
        issuer2.approve(user);
        assertTrue(gate.isAllowed(user));
    }

    function testIsAllowedReturnsFalseWhenAllIssuersDeny() public {
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        gate.addIssuer(IBullaKycIssuer(address(issuer2)));
        // Neither issuer approves user
        assertFalse(gate.isAllowed(user));
    }

    function testAddIssuerAndGetIssuers() public {
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        gate.addIssuer(IBullaKycIssuer(address(issuer2)));
        IBullaKycIssuer[] memory result = gate.getIssuers();
        assertEq(result.length, 2);
        assertEq(address(result[0]), address(issuer1));
        assertEq(address(result[1]), address(issuer2));
    }

    function testRemoveIssuerSwapAndPop() public {
        ManualBullaKycIssuer issuer3 = new ManualBullaKycIssuer();
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        gate.addIssuer(IBullaKycIssuer(address(issuer2)));
        gate.addIssuer(IBullaKycIssuer(address(issuer3)));

        // Remove issuer1 (index 0) — issuer3 should take its place
        gate.removeIssuer(0);
        IBullaKycIssuer[] memory result = gate.getIssuers();
        assertEq(result.length, 2);
        assertEq(address(result[0]), address(issuer3));
        assertEq(address(result[1]), address(issuer2));
    }

    function testRemoveIssuerInvalidIndex() public {
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        vm.expectRevert(abi.encodeWithSignature("InvalidIssuerIndex()"));
        gate.removeIssuer(1);
    }

    function testCannotAddMoreThan256Issuers() public {
        for (uint256 i = 0; i < 256; i++) {
            ManualBullaKycIssuer newIssuer = new ManualBullaKycIssuer();
            gate.addIssuer(IBullaKycIssuer(address(newIssuer)));
        }
        ManualBullaKycIssuer extraIssuer = new ManualBullaKycIssuer();
        vm.expectRevert(abi.encodeWithSignature("MaxIssuersReached()"));
        gate.addIssuer(IBullaKycIssuer(address(extraIssuer)));
    }

    function testAddIssuerInvalidAddress() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidIssuer()"));
        gate.addIssuer(IBullaKycIssuer(address(0)));
    }

    function testNonOwnerCannotAddIssuer() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        vm.stopPrank();
    }

    function testNonOwnerCannotRemoveIssuer() public {
        gate.addIssuer(IBullaKycIssuer(address(issuer1)));
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        gate.removeIssuer(0);
        vm.stopPrank();
    }
}

// ============ Integration Test: BullaKycGate with BullaFactoring ============

contract TestKycGateIntegration is CommonSetup {
    BullaKycGate public kycGate;
    ManualBullaKycIssuer public kycIssuer;
    BullaFactoringV2_2 public kycFactoring;

    function setUp() public override {
        super.setUp();

        // Deploy KYC gate and issuer
        kycGate = new BullaKycGate();
        kycIssuer = new ManualBullaKycIssuer();
        kycGate.addIssuer(IBullaKycIssuer(address(kycIssuer)));

        // Deploy a new factoring contract with the KYC gate as depositPermissions
        kycFactoring = new BullaFactoringV2_2(
            asset,
            invoiceAdapterBulla,
            bullaFrendLend,
            underwriter,
            kycGate,            // KYC gate as deposit permissions
            redeemPermissions,
            factoringPermissions,
            bullaDao,
            protocolFeeBps,
            adminFeeBps,
            poolName,
            targetYield,
            poolTokenName,
            poolTokenSymbol,
            address(0x1999),
            uint16(100),
            uint16(500),
            uint16(5000)
        );
    }

    function testNonKycUserCannotDeposit() public {
        uint256 depositAmount = 100 ether;

        vm.startPrank(alice);
        asset.approve(address(kycFactoring), depositAmount);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", alice));
        kycFactoring.deposit(depositAmount, alice);
        vm.stopPrank();
    }

    function testKycUserCanDeposit() public {
        uint256 depositAmount = 100 ether;

        // Approve alice via KYC issuer
        kycIssuer.approve(alice);

        vm.startPrank(alice);
        asset.approve(address(kycFactoring), depositAmount);
        uint256 shares = kycFactoring.deposit(depositAmount, alice);
        vm.stopPrank();

        assertGt(shares, 0);
    }
}
