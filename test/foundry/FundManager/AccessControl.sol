// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BullaFactoringFundManager} from "contracts/FactoringFundManager.sol";
import {CommonSetup} from "../CommonSetup.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract FactoringFundManagerAccessControlTest is CommonSetup {
    BullaFactoringFundManager public fundManager;

    // Test accounts
    address public owner = address(0x1111);
    address public capitalCaller = address(0x2222);
    address public nonOwner = address(0x1234);
    address public newCapitalCaller = address(0x5678);

    function setUp() public override {
        super.setUp();

        // Deploy FundManager with designated owner and capitalCaller
        vm.startPrank(owner);
        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(bullaFactoring),
            _minInvestment: 10e6,
            _capitalCaller: capitalCaller
        });
        fundManager.transferOwnership(owner);
        vm.label(address(fundManager), "FundManager");
        vm.label(address(bullaFactoring), "BullaFactoring");
        vm.label(address(owner), "Owner");
        vm.label(address(capitalCaller), "CapitalCaller");
        vm.label(address(nonOwner), "NonOwner");
        vm.label(address(newCapitalCaller), "NewCapitalCaller");

        depositPermissions.allow(address(fundManager));
        vm.stopPrank();
    }

    //
    //// HELPER FUNCTIONS
    //

    // Helper function to commit investments for multiple investors
    function _commitInvestments(address investor, uint256 amount) internal {
        vm.startPrank(investor);
        asset.approve(address(fundManager), amount);
        fundManager.commit(amount);
        vm.stopPrank();
    }

    //
    //// TESTS
    //

    /// @notice SPEC: C1 - Only owner can allowlist investors (Fail Scenario)
    function test_onlyOwnerCanAllowlistInvestor_fail() public {
        // Arrange
        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()")); // SPEC: C1
        fundManager.allowlistInvestor(nonOwner);

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only owner can allowlist investors (Pass Scenario)
    function test_onlyOwnerCanAllowlistInvestor_pass() public {
        // Arrange
        vm.startPrank(owner);

        // Act
        fundManager.allowlistInvestor(nonOwner);

        // Assert
        (bool isAllowed, uint144 commitment) = fundManager.capitalCommitments(nonOwner);
        assertTrue(isAllowed, "Non-owner should be allowlisted by owner"); // SPEC: E1
        assertTrue(commitment == 0, "Commitment should be 0"); // SPEC: E1

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only owner can blocklist investors (Fail Scenario)
    function test_onlyOwnerCanBlocklistInvestor_fail() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.allowlistInvestor(nonOwner);
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()")); // SPEC: C1
        fundManager.blocklistInvestor(nonOwner);

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only owner can blocklist investors (Pass Scenario)
    function test_onlyOwnerCanBlocklistInvestor_pass() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.allowlistInvestor(nonOwner);

        // Act
        fundManager.blocklistInvestor(nonOwner);

        // Assert
        (bool isAllowed,) = fundManager.capitalCommitments(nonOwner);
        assertFalse(isAllowed, "Non-owner should be blocklisted by owner"); // SPEC: E1

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only owner can set minimum investment (Fail Scenario)
    function test_onlyOwnerCanSetMinInvestment_fail() public {
        // Arrange
        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()")); // SPEC: C1
        fundManager.setMinInvestment(20e6);

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only owner can set minimum investment (Pass Scenario)
    function test_onlyOwnerCanSetMinInvestment_pass() public {
        // Arrange
        vm.startPrank(owner);

        // Act
        fundManager.setMinInvestment(20e6);

        // Assert
        assertEq(fundManager.minInvestment(), 20e6, "Min investment should be updated by owner"); // SPEC: E2

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only capitalCaller or owner can perform capital call (Fail Scenario)
    function test_onlyCapitalCallerCanPerformCapitalCall_fail(address caller) public {
        // Arrange
        vm.prank(owner);
        fundManager.allowlistInvestor(nonOwner);

        vm.assume(caller != owner && caller != capitalCaller);

        vm.startPrank(caller);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()")); // SPEC: C1
        fundManager.capitalCall(1 ether);

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only capitalCaller or owner can perform capital call (Pass Scenario)
    function test_onlyCapitalCallerCanPerformCapitalCall_pass() public {
        // Arrange
        vm.prank(owner);
        fundManager.allowlistInvestor(nonOwner);

        asset.mint(nonOwner, 1 ether);
        _commitInvestments(nonOwner, 1 ether);

        // Act
        vm.prank(capitalCaller);
        (uint256 amountCalled,) = fundManager.capitalCall(.5 ether);

        // Assert
        assertEq(amountCalled, .5 ether, "Capital call should be executed by owner or capitalCaller"); // SPEC: E1

        vm.prank(owner);
        (uint256 amountCalled2,) = fundManager.capitalCall(.5 ether);

        assertEq(amountCalled2, .5 ether, "Capital call should be executed by owner or capitalCaller"); // SPEC: E1
    }

    /// @notice SPEC: C1 - Only owner can set capitalCaller (Fail Scenario)
    function test_setCapitalCaller_fail() public {
        // Arrange
        vm.startPrank(nonOwner);

        // Act & Assert
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()")); // SPEC: C1
        fundManager.setCapitalCaller(newCapitalCaller);

        vm.stopPrank();
    }

    /// @notice SPEC: C1 - Only owner can set capitalCaller (Pass Scenario)
    function test_setCapitalCaller_pass() public {
        // Arrange
        vm.startPrank(owner);

        // Act
        fundManager.setCapitalCaller(newCapitalCaller);

        // Assert
        assertEq(fundManager.capitalCaller(), newCapitalCaller, "Capital caller should be updated by owner"); // SPEC: E3

        vm.stopPrank();
    }

    /// @notice SPEC: E1 - New capitalCaller can perform capital call
    function test_newCapitalCallerCanPerformCapitalCall() public {
        // Arrange
        vm.startPrank(owner);
        fundManager.setCapitalCaller(newCapitalCaller);
        fundManager.allowlistInvestor(nonOwner);
        asset.mint(nonOwner, 1 ether);
        _commitInvestments(nonOwner, 1 ether);
        vm.stopPrank();

        // Act
        vm.prank(newCapitalCaller);
        (uint256 amountCalled,) = fundManager.capitalCall(1 ether);

        // Assert
        assertEq(amountCalled, 1 ether, "New capital caller should be able to perform capital call"); // SPEC: E1

        vm.stopPrank();
    }
}
