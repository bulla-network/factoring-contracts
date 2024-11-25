// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BullaFactoringFundManager} from "contracts/FundManager.sol";
import {CommonSetup} from "../CommonSetup.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract FundManagerTest is CommonSetup {
    BullaFactoringFundManager public fundManager;

    // Test accounts
    address public owner = address(address(this));

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        fundManager = new BullaFactoringFundManager({_factoringPool: IERC4626(bullaFactoring), _minInvestment: 10e6});
        depositPermissions.allow(address(fundManager));
    }

    function test_happyPath() public {
        // bob and alice deposit
        vm.startPrank(owner);
        fundManager.allowlistInvestor({investor: alice});
        fundManager.allowlistInvestor({investor: bob});
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(fundManager), 1 ether);
        fundManager.commit({amount: 1 ether});
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(fundManager), 2 ether);
        fundManager.commit({amount: 2 ether});
        vm.stopPrank();

        assertEq(fundManager.totalCommitted(), 3 ether);

        // a capital call is executed
        vm.prank(owner);
        fundManager.capitalCall({callAmount: 2 ether});

        assertEq(fundManager.investorCount(), 2);
        assertEq(fundManager.totalCommitted(), 1 ether);
    }
}
