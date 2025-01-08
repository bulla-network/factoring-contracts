// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BullaFactoringFundManager} from "contracts/FundManager.sol";
import {CommonSetup} from "../CommonSetup.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract FactoringFundManagerAccessControlTest is CommonSetup {
    BullaFactoringFundManager public fundManager;

    // Test accounts
    address public owner = address(this);
    address public nonOwner = address(0x1234);
    address public newCapitalCaller = address(0x5678);

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(bullaFactoring),
            _minInvestment: 10e6,
            _capitalCaller: address(this)
        });
        depositPermissions.allow(address(fundManager));
        vm.stopPrank();
    }

    function test_onlyOwnerCanAllowlistInvestor_fail() public {
        // Arrange
        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.allowlistInvestor(nonOwner);

        vm.stopPrank();
    }

    function test_onlyOwnerCanAllowlistInvestor_pass() public {
        // Arrange
        vm.startPrank(owner);

        // Act
        fundManager.allowlistInvestor(nonOwner);

        // Assert
        (bool isAllowed,) = fundManager.capitalCommitments(nonOwner);
        assertTrue(isAllowed, "Non-owner should be allowlisted by owner");

        vm.stopPrank();
    }

    function test_onlyOwnerCanBlocklistInvestor_fail() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.allowlistInvestor(nonOwner);
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.blocklistInvestor(nonOwner);

        vm.stopPrank();
    }

    function test_onlyOwnerCanBlocklistInvestor_pass() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.allowlistInvestor(nonOwner);

        // Act
        fundManager.blocklistInvestor(nonOwner);

        // Assert
        (bool isAllowed,) = fundManager.capitalCommitments(nonOwner);
        assertFalse(isAllowed, "Non-owner should be blocklisted by owner");

        vm.stopPrank();
    }

    function test_onlyOwnerCanSetMinInvestment_fail() public {
        // Arrange
        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.setMinInvestment(20e6);

        vm.stopPrank();
    }

    function test_onlyOwnerCanSetMinInvestment_pass() public {
        // Arrange
        vm.startPrank(owner);

        // Act
        fundManager.setMinInvestment(20e6);

        // Assert
        assertEq(fundManager.minInvestment(), 20e6, "Min investment should be updated by owner");

        vm.stopPrank();
    }

    function test_onlyCapitalCallerCanPerformCapitalCall_fail() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.allowlistInvestor(nonOwner);
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.capitalCall(1 ether);

        vm.stopPrank();
    }

    function test_onlyCapitalCallerCanPerformCapitalCall_pass() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.allowlistInvestor(nonOwner);
        asset.mint(nonOwner, 1 ether);
        _commitInvestments(nonOwner, 1 ether);

        // Act
        (uint256 amountCalled,) = fundManager.capitalCall(1 ether);

        // Assert
        assertEq(amountCalled, 1 ether, "Owner should be able to perform capital call");

        vm.stopPrank();
    }

    function test_setCapitalCaller_fail() public {
        // Arrange
        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.setCapitalCaller(newCapitalCaller);

        vm.stopPrank();
    }

    function test_setCapitalCaller_pass() public {
        // Arrange
        vm.startPrank(owner);

        // Act
        fundManager.setCapitalCaller(newCapitalCaller);

        // Assert
        assertEq(fundManager.capitalCaller(), newCapitalCaller, "Capital caller should be updated by owner");

        vm.stopPrank();
    }

    function test_newCapitalCallerCanPerformCapitalCall() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.setCapitalCaller(newCapitalCaller);
        fundManager.allowlistInvestor(nonOwner);
        asset.mint(nonOwner, 1 ether);
        _commitInvestments(nonOwner, 1 ether);
        vm.stopPrank();

        vm.startPrank(newCapitalCaller);

        // Act
        (uint256 amountCalled,) = fundManager.capitalCall(1 ether);

        // Assert
        assertEq(amountCalled, 1 ether, "New capital caller should be able to perform capital call");

        vm.stopPrank();
    }

    // Helper function to commit investments for multiple investors
    function _commitInvestments(address investor, uint256 amount) internal {
        vm.startPrank(investor);
        asset.approve(address(fundManager), amount);
        fundManager.commit(amount);
        vm.stopPrank();
    }
}
