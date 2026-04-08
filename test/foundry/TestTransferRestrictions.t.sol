// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_2 } from 'contracts/BullaFactoring.sol';
import { CommonSetup } from './CommonSetup.t.sol';

contract TestTransferRestrictions is CommonSetup {

    uint256 constant DEPOSIT_AMOUNT = 100000;

    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        shares = bullaFactoring.deposit(amount, user);
        vm.stopPrank();
    }

    function testTransferBetweenApprovedAddresses() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        bullaFactoring.transfer(bob, shares);
        vm.stopPrank();

        assertEq(bullaFactoring.balanceOf(bob), shares);
        assertEq(bullaFactoring.balanceOf(alice), 0);
    }

    function testTransferToUnapprovedAddressReverts() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedTransfer(address)", charlie));
        bullaFactoring.transfer(charlie, shares);
        vm.stopPrank();
    }

    function testTransferFromUnapprovedSenderReverts() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        // Remove alice from deposit permissions
        depositPermissions.disallow(alice);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedTransfer(address)", alice));
        bullaFactoring.transfer(bob, shares);
        vm.stopPrank();
    }

    function testTransferFromApprovedWithApproval() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        // alice approves bob to spend her shares
        vm.startPrank(alice);
        bullaFactoring.approve(bob, shares);
        vm.stopPrank();

        // bob transfers alice's shares to himself
        vm.startPrank(bob);
        bullaFactoring.transferFrom(alice, bob, shares);
        vm.stopPrank();

        assertEq(bullaFactoring.balanceOf(bob), shares);
        assertEq(bullaFactoring.balanceOf(alice), 0);
    }

    function testTransferFromToUnapprovedReverts() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        // alice approves bob to spend her shares
        vm.startPrank(alice);
        bullaFactoring.approve(bob, shares);
        vm.stopPrank();

        // bob tries to transfer alice's shares to charlie (unapproved)
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedTransfer(address)", charlie));
        bullaFactoring.transferFrom(alice, charlie, shares);
        vm.stopPrank();
    }

    function testDepositStillWorksForApprovedUser() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);
        assertGt(shares, 0);
        assertEq(bullaFactoring.balanceOf(alice), shares);
    }

    function testRedeemStillWorksForApprovedUser() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        vm.startPrank(alice);
        uint256 assets = bullaFactoring.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(assets, 0);
        assertEq(bullaFactoring.balanceOf(alice), 0);
    }

    function testNewlyApprovedAddressCanReceiveTransfer() public {
        uint256 shares = _depositAs(alice, DEPOSIT_AMOUNT);

        // charlie is not approved initially — add him
        depositPermissions.allow(charlie);

        vm.startPrank(alice);
        bullaFactoring.transfer(charlie, shares);
        vm.stopPrank();

        assertEq(bullaFactoring.balanceOf(charlie), shares);
    }

    function testRemovedUserCannotTransfer() public {
        uint256 shares = _depositAs(bob, DEPOSIT_AMOUNT);

        // Remove bob from deposit permissions after deposit
        depositPermissions.disallow(bob);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedTransfer(address)", bob));
        bullaFactoring.transfer(alice, shares);
        vm.stopPrank();
    }
}
