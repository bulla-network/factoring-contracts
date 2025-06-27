// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2 } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimV1InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV1InvoiceProviderAdapterV2.sol';
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

contract TestErrorHandlingAndEdgeCases is CommonSetup {
    event GracePeriodDaysChanged(uint256 newGracePeriodDays);
    event ApprovalDurationChanged(uint256 newApprovalDuration);
    event UnderwriterChanged(address indexed oldUnderwriter, address indexed newUnderwriter);

    function testSetUnderwriterOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setUnderwriter(alice);
        vm.stopPrank();
    }

    function testSetApprovalDurationOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setApprovalDuration(10);
        vm.stopPrank();
    }

    function testSetGracePeriodDaysOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setGracePeriodDays(10);
        vm.stopPrank();
    }

    function testWithdrawAdminFeesOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.withdrawAdminFeesAndSpreadGains();
        vm.stopPrank();
    }

    function testSetBullaDaoAddressOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerNotBullaDao()"));
        bullaFactoring.setBullaDaoAddress(bob);
        vm.stopPrank();
    }

    function testSetProtocolFeeBpsOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("CallerNotBullaDao()"));
        bullaFactoring.setProtocolFeeBps(0);
        vm.stopPrank();
    }

    function testSetAdminFeeBpsOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setAdminFeeBps(0);
        vm.stopPrank();
    }

    function testSetDepositPermissionsOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setDepositPermissions(bob);
        vm.stopPrank();
    }

    function testSetFactoringPermissionsOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setFactoringPermissions(bob);
        vm.stopPrank();
    }

    function testSetTargetYieldOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.setTargetYield(0);
        vm.stopPrank();
    }

    function testImpairInvoiceOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        bullaFactoring.impairInvoice(0);
        vm.stopPrank();
    }

    function testSetUnderwriterEmitsEvent() public {
        address oldUnderwriter = bullaFactoring.underwriter();
        address newUnderwriter = alice;
        
        vm.expectEmit(true, true, true, true);
        emit UnderwriterChanged(oldUnderwriter, newUnderwriter);
        bullaFactoring.setUnderwriter(newUnderwriter);
        
        assertEq(bullaFactoring.underwriter(), newUnderwriter, "Underwriter should be updated");
    }

    function testSetGracePeriodDaysEmitsEvent() public {
        uint256 oldGracePeriodDays = bullaFactoring.gracePeriodDays();
        uint256 newGracePeriodDays = 90;
        
        vm.expectEmit(true, true, true, true);
        emit GracePeriodDaysChanged(newGracePeriodDays);
        bullaFactoring.setGracePeriodDays(newGracePeriodDays);
        
        assertEq(bullaFactoring.gracePeriodDays(), newGracePeriodDays, "Grace period days should be updated");
    }

    function testSetApprovalDurationEmitsEvent() public {
        uint256 oldApprovalDuration = bullaFactoring.approvalDuration();
        uint256 newApprovalDuration = 7200; // 2 hours
        
        vm.expectEmit(true, true, true, true);
        emit ApprovalDurationChanged(newApprovalDuration);
        bullaFactoring.setApprovalDuration(newApprovalDuration);
        
        assertEq(bullaFactoring.approvalDuration(), newApprovalDuration, "Approval duration should be updated");
    }
}
