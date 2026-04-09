// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { AgreementSignatureRepo } from 'contracts/AgreementSignatureRepo.sol';

contract TestAgreementSignatureRepo is Test {
    AgreementSignatureRepo public repo;
    address owner;
    address approver = address(0xA001);
    address nonApprover = address(0xBEEF);
    address pool = address(0x1111);
    uint256 documentVersion = 1;
    address participant = address(0xCAFE);

    function setUp() public {
        owner = address(this);
        repo = new AgreementSignatureRepo(approver);
    }

    function testRecordSignatureSetsHasSignedToTrue() public {
        assertFalse(repo.hasSigned(pool, documentVersion, participant));
        vm.prank(approver);
        repo.recordSignature(pool, documentVersion, participant);
        assertTrue(repo.hasSigned(pool, documentVersion, participant));
    }

    function testRevokeSignatureSetsHasSignedToFalse() public {
        vm.prank(approver);
        repo.recordSignature(pool, documentVersion, participant);
        assertTrue(repo.hasSigned(pool, documentVersion, participant));
        vm.prank(approver);
        repo.revokeSignature(pool, documentVersion, participant);
        assertFalse(repo.hasSigned(pool, documentVersion, participant));
    }

    function testOwnerCanSetSignatureApprover() public {
        address newApprover = address(0xA002);
        repo.setSignatureApprover(newApprover);
        assertEq(repo.signatureApprover(), newApprover);
    }

    function testOwnerCannotDirectlyRecordSignature() public {
        vm.expectRevert(abi.encodeWithSelector(AgreementSignatureRepo.UnauthorizedSignatureApprover.selector, owner));
        repo.recordSignature(pool, documentVersion, participant);
    }

    function testOwnerCannotDirectlyRevokeSignature() public {
        vm.prank(approver);
        repo.recordSignature(pool, documentVersion, participant);
        vm.expectRevert(abi.encodeWithSelector(AgreementSignatureRepo.UnauthorizedSignatureApprover.selector, owner));
        repo.revokeSignature(pool, documentVersion, participant);
    }

    function testNonApproverCannotRecordSignature() public {
        vm.startPrank(nonApprover);
        vm.expectRevert(abi.encodeWithSelector(AgreementSignatureRepo.UnauthorizedSignatureApprover.selector, nonApprover));
        repo.recordSignature(pool, documentVersion, participant);
        vm.stopPrank();
    }

    function testNonApproverCannotRevokeSignature() public {
        vm.prank(approver);
        repo.recordSignature(pool, documentVersion, participant);
        vm.startPrank(nonApprover);
        vm.expectRevert(abi.encodeWithSelector(AgreementSignatureRepo.UnauthorizedSignatureApprover.selector, nonApprover));
        repo.revokeSignature(pool, documentVersion, participant);
        vm.stopPrank();
    }

    function testNonOwnerCannotSetSignatureApprover() public {
        vm.startPrank(nonApprover);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonApprover));
        repo.setSignatureApprover(address(0xA003));
        vm.stopPrank();
    }

    function testNewApproverCanRecordAfterChange() public {
        address newApprover = address(0xA002);
        repo.setSignatureApprover(newApprover);

        // New approver can record
        vm.prank(newApprover);
        repo.recordSignature(pool, documentVersion, participant);
        assertTrue(repo.hasSigned(pool, documentVersion, participant));

        // Old approver can no longer record
        address anotherParticipant = address(0xCAFF);
        vm.startPrank(approver);
        vm.expectRevert(abi.encodeWithSelector(AgreementSignatureRepo.UnauthorizedSignatureApprover.selector, approver));
        repo.recordSignature(pool, documentVersion, anotherParticipant);
        vm.stopPrank();
    }

    function testMultiplePoolsAndVersionsAreIndependent() public {
        address pool1 = address(0x1111);
        address pool2 = address(0x2222);
        uint256 version1 = 1;
        uint256 version2 = 2;
        address user1 = address(0xCAFE);

        // Record signature for pool1/version1/user1
        vm.prank(approver);
        repo.recordSignature(pool1, version1, user1);

        // Verify pool1/version1/user1 is signed
        assertTrue(repo.hasSigned(pool1, version1, user1));

        // Verify pool2/version1/user1 is NOT signed
        assertFalse(repo.hasSigned(pool2, version1, user1));

        // Verify pool1/version2/user1 is NOT signed
        assertFalse(repo.hasSigned(pool1, version2, user1));

        // Verify pool2/version2/user1 is NOT signed
        assertFalse(repo.hasSigned(pool2, version2, user1));
    }
}
