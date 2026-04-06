// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { SumsubKycIssuer } from 'contracts/SumsubKycIssuer.sol';
import { ManualBullaKycIssuer } from 'contracts/ManualBullaKycIssuer.sol';
import { BullaKycGate } from 'contracts/BullaKycGate.sol';
import { IBullaKycIssuer } from 'contracts/interfaces/IBullaKycIssuer.sol';

// ============ Unit Tests: SumsubKycIssuer ============

contract TestSumsubKycIssuer is Test {
    SumsubKycIssuer public issuer;
    address owner;
    address approver = address(0xA001);
    address nonApprover = address(0xBEEF);
    address user = address(0xCAFE);

    function setUp() public {
        owner = address(this);
        issuer = new SumsubKycIssuer(approver);
    }

    function testApproveSetIsKycedToTrue() public {
        assertFalse(issuer.isKyced(user));
        vm.prank(approver);
        issuer.approve(user);
        assertTrue(issuer.isKyced(user));
    }

    function testRevokeSetIsKycedToFalse() public {
        vm.prank(approver);
        issuer.approve(user);
        assertTrue(issuer.isKyced(user));
        vm.prank(approver);
        issuer.revoke(user);
        assertFalse(issuer.isKyced(user));
    }

    function testOwnerCanSetKycApprover() public {
        address newApprover = address(0xA002);
        issuer.setKycApprover(newApprover);
        assertEq(issuer.kycApprover(), newApprover);
    }

    function testOwnerCannotDirectlyApprove() public {
        vm.expectRevert(abi.encodeWithSelector(SumsubKycIssuer.UnauthorizedKycApprover.selector, owner));
        issuer.approve(user);
    }

    function testOwnerCannotDirectlyRevoke() public {
        vm.prank(approver);
        issuer.approve(user);
        vm.expectRevert(abi.encodeWithSelector(SumsubKycIssuer.UnauthorizedKycApprover.selector, owner));
        issuer.revoke(user);
    }

    function testNonApproverCannotApprove() public {
        vm.startPrank(nonApprover);
        vm.expectRevert(abi.encodeWithSelector(SumsubKycIssuer.UnauthorizedKycApprover.selector, nonApprover));
        issuer.approve(user);
        vm.stopPrank();
    }

    function testNonApproverCannotRevoke() public {
        vm.prank(approver);
        issuer.approve(user);
        vm.startPrank(nonApprover);
        vm.expectRevert(abi.encodeWithSelector(SumsubKycIssuer.UnauthorizedKycApprover.selector, nonApprover));
        issuer.revoke(user);
        vm.stopPrank();
    }

    function testNonOwnerCannotSetKycApprover() public {
        vm.startPrank(nonApprover);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonApprover));
        issuer.setKycApprover(address(0xA003));
        vm.stopPrank();
    }

    function testNewApproverCanApproveAfterChange() public {
        address newApprover = address(0xA002);
        issuer.setKycApprover(newApprover);

        // New approver can approve
        vm.prank(newApprover);
        issuer.approve(user);
        assertTrue(issuer.isKyced(user));

        // Old approver can no longer approve
        address anotherUser = address(0xCAFF);
        vm.startPrank(approver);
        vm.expectRevert(abi.encodeWithSelector(SumsubKycIssuer.UnauthorizedKycApprover.selector, approver));
        issuer.approve(anotherUser);
        vm.stopPrank();
    }
}

// ============ Integration Test: SumsubKycIssuer with BullaKycGate ============

contract TestSumsubKycIssuerWithGate is Test {
    BullaKycGate public gate;
    ManualBullaKycIssuer public manualIssuer;
    SumsubKycIssuer public sumsubIssuer;
    address approver = address(0xA001);
    address user1 = address(0xCAFE);
    address user2 = address(0xBEEF);
    address user3 = address(0xDEAD);

    function setUp() public {
        gate = new BullaKycGate();
        manualIssuer = new ManualBullaKycIssuer();
        sumsubIssuer = new SumsubKycIssuer(approver);

        gate.addIssuer(IBullaKycIssuer(address(manualIssuer)));
        gate.addIssuer(IBullaKycIssuer(address(sumsubIssuer)));
    }

    function testSumsubOnlyApprovalAllowsUser() public {
        vm.prank(approver);
        sumsubIssuer.approve(user1);
        assertTrue(gate.isAllowed(user1));
    }

    function testManualOnlyApprovalAllowsUser() public {
        manualIssuer.approve(user2);
        assertTrue(gate.isAllowed(user2));
    }

    function testUnapprovedUserIsNotAllowed() public view {
        assertFalse(gate.isAllowed(user3));
    }
}
