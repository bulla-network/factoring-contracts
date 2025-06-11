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

contract TestErrorHandlingAndEdgeCases is CommonSetup {
    function testSetUnderwriterOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setUnderwriter(alice);
        vm.stopPrank();
    }

    function testSetApprovalDurationOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setApprovalDuration(10);
        vm.stopPrank();
    }

    function testSetGracePeriodDaysOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setGracePeriodDays(10);
        vm.stopPrank();
    }

    function testWithdrawAdminFeesOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.withdrawAdminFees();
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
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setAdminFeeBps(0);
        vm.stopPrank();
    }

    function testSetDepositPermissionsOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setDepositPermissions(bob);
        vm.stopPrank();
    }

    function testSetFactoringPermissionsOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setFactoringPermissions(bob);
        vm.stopPrank();
    }

    function testSetTargetYieldOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.setTargetYield(0);
        vm.stopPrank();
    }

    function testImpairInvoiceOnlyCalledByOwner() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        bullaFactoring.impairInvoice(0);
        vm.stopPrank();
    }
}
