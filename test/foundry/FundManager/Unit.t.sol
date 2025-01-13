// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BullaFactoringFundManager} from "contracts/FactoringFundManager.sol";
import {CommonSetup} from "../CommonSetup.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract FactoringFundManagerUnitTest is CommonSetup {
    BullaFactoringFundManager public fundManager;

    // Test accounts
    address public owner = address(address(this));
    address public charlie = address(0x1234);

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(bullaFactoring),
            _minInvestment: 10e6,
            _capitalCaller: address(this)
        });
        depositPermissions.allow(address(fundManager));
    }

    //
    //// HELPER FUNCTIONS
    //

    // Helper function to allowlist a single investor
    function _allowlistInvestor(address investor) internal {
        vm.startPrank(owner);
        fundManager.allowlistInvestor(investor);
        vm.stopPrank();
    }

    // Helper function to allowlist multiple investors
    function _allowlistInvestors(address[] memory investorsToAllow) internal {
        vm.startPrank(owner);
        for (uint256 i = 0; i < investorsToAllow.length; i++) {
            fundManager.allowlistInvestor(investorsToAllow[i]);
        }
        vm.stopPrank();
    }

    // Helper function to commit investments for multiple investors
    function _commitInvestments(address investor, uint256 amount) internal {
        vm.startPrank(investor);
        asset.approve(address(fundManager), amount);
        fundManager.commit(amount);
        vm.stopPrank();
    }

    // Helper function to make an investor go insolvent
    function _goInsolvent(address investor) internal {
        vm.startPrank(investor);
        asset.transfer(address(0xdead), asset.balanceOf(investor));
        vm.stopPrank();
    }

    // Helper function to perform a capital call
    function _capitalCall(uint256 amount) internal returns (uint256, uint256) {
        vm.prank(owner);
        return fundManager.capitalCall(amount);
    }

    //
    //// TESTS
    //
    function test_happyPath() public {
        // Arrange
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        uint256 bobBalanceBefore = asset.balanceOf(bob);
        address[] memory investorsToAllow = new address[](2);
        investorsToAllow[0] = alice;
        investorsToAllow[1] = bob;
        _allowlistInvestors(investorsToAllow);

        // Act
        _commitInvestments(alice, 2 ether);
        _commitInvestments(bob, 2 ether);

        // Assert
        assertEq(fundManager.totalCommitted(), 4 ether, "Total committed should be 3 ether");
        assertEq(fundManager.investorCount(), 2, "There should be 2 investors");

        // Capital Call
        (uint256 totalAmountCalled,) = _capitalCall(2 ether);

        assertEq(totalAmountCalled, 2 ether, "2 ether should've been called");
        assertEq(asset.balanceOf(address(alice)), aliceBalanceBefore - 1 ether, "Alice should have 1 ether less");
        assertEq(asset.balanceOf(address(bob)), bobBalanceBefore - 1 ether, "Bob should have 1 ether less");
        assertEq(
            asset.balanceOf(address(fundManager.factoringPool())), 2 ether, "The factoring pool should now have 2 ether"
        );
        assertEq(bullaFactoring.totalSupply(), 2 ether, "The factoring pool should have minted 2 ether of shares");

        assertEq(
            fundManager.totalCommitted(),
            4 ether - totalAmountCalled,
            "Total committed should be 1 ether after capital call"
        );
        assertEq(fundManager.investorCount(), 2, "Investor count should remain 2 after capital call");

        // Clear out the fund
        uint256 targetAmount = fundManager.totalCommitted();
        ( totalAmountCalled,) = _capitalCall(targetAmount);
        assertEq(fundManager.totalCommitted(), 0, "Total committed should be 0 after capital call");

        uint256 individualAdditiveCommitment;
        for (uint256 i = 0; i < fundManager.investorCount(); i++) {
            (, uint144 commitment) = fundManager.capitalCommitments(fundManager.investors(i));
            individualAdditiveCommitment += uint256(commitment);
        }
        assertEq(individualAdditiveCommitment, 0, "Individual commitments should add to 0 (no dust)");
    }

    function test_commitBelowMinimumInvestment() public {
        // Arrange
        _allowlistInvestor(alice);

        // Act & Assert
        vm.startPrank(alice);
        uint256 investment = fundManager.minInvestment() - 1;
        asset.approve(address(fundManager), investment);
        vm.expectRevert(abi.encodeWithSignature("CommitmentTooLow()"));
        fundManager.commit(investment);
        vm.stopPrank();
    }

    function test_commitAboveMaximumInvestment() public {
        // Arrange
        _allowlistInvestor(alice);

        // Act & Assert
        vm.startPrank(alice);
        asset.approve(address(fundManager), uint256(type(uint144).max) + 1);
        vm.expectRevert(abi.encodeWithSignature("CommitmentTooHigh()"));
        fundManager.commit(uint256(type(uint144).max) + 1);
        vm.stopPrank();
    }

    function test_commitWithInsufficientAllowance() public {
        // Arrange
        _allowlistInvestor(alice);

        // Act & Assert
        vm.startPrank(alice);
        asset.approve(address(fundManager), 0); // No allowance
        vm.expectRevert(abi.encodeWithSignature("BadERC20Allowance(uint256)", 0));
        fundManager.commit(1 ether);
        vm.stopPrank();
    }

    function test_commitWithInsufficientBalance() public {
        // Arrange
        _allowlistInvestor(alice);

        _commitInvestments(alice, 1 ether);
        _goInsolvent(alice);

        vm.expectRevert(abi.encodeWithSignature("BadERC20Balance(uint256)", 0));

        vm.prank(alice);
        fundManager.commit(1 ether);
    }

    function test_updateExistingCommitment() public {
        // Arrange
        _allowlistInvestor(alice);

        _commitInvestments(alice, 1 ether);

        // Act
        _commitInvestments(alice, 2 ether); // Update commitment from 1 ether to 2 ether

        // Destructure the capital commitment struct for Alice
        (, uint144 commitment) = fundManager.capitalCommitments(alice);

        // Assert
        assertEq(commitment, 2 ether, "Alice's commitment should be updated to 2 ether");
        assertEq(fundManager.totalCommitted(), 2 ether, "Total committed should be 2 ether after update");
    }

    function test_unauthorizedAllowlist() public {
        // Arrange
        address unauthorizedUser = address(0x123);

        // Act & Assert
        vm.startPrank(unauthorizedUser);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.allowlistInvestor(alice);
        vm.stopPrank();
    }

    function test_capitalCallExceedingTotalCommitted() public {
        // Arrange
        _allowlistInvestor(alice);
        _commitInvestments(alice, 1 ether);

        // Act & Assert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("CallTooHigh()"));
        fundManager.capitalCall(2 ether);
    }

    function test_handlingInsolventInvestors() public {
        // Arrange
        address[] memory investorsToAllow = new address[](2);
        investorsToAllow[0] = alice;
        investorsToAllow[1] = bob;
        _allowlistInvestors(investorsToAllow);
        _commitInvestments(alice, 1 ether);
        _commitInvestments(bob, 2 ether);

        // Simulate insolvency by having bob spend all his money
        _goInsolvent(bob);

        // Act
        uint256 targetCallAmount = 2 ether;
        (uint256 totalAmountCalled,) = _capitalCall(targetCallAmount);

        // Assert
        assertLt(totalAmountCalled, targetCallAmount, "Total called should be less than target call amount");
        assertEq(fundManager.investorCount(), 1, "Investor count should be 1 after removing insolvent investor");
    }

    function test_blocklistInvestor() public {
        // Arrange
        _allowlistInvestor(alice);
        _commitInvestments(alice, 1 ether);

        // Act
        vm.prank(owner);
        fundManager.blocklistInvestor(alice);

        // Assert
        assertEq(fundManager.investorCount(), 0, "Investor count should be 0 after blocklisting");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        fundManager.commit(1 ether);
        vm.stopPrank();
    }

    function test_maxCapitalCallCalculation() public {
        // Arrange
        address[] memory investorsToAllow = new address[](2);
        investorsToAllow[0] = alice;
        investorsToAllow[1] = bob;
        _allowlistInvestors(investorsToAllow);
        _commitInvestments(alice, 1 ether);
        _commitInvestments(bob, 2 ether);

        // Act
        uint256 maxCapitalCall = fundManager.totalCommitted();

        // Assert
        assertEq(maxCapitalCall, 3 ether, "Max capital call should be 3 ether");
    }

    // test alice deposits 1 eth, then gets capital called at 1 eth, then deposits another eth
    function test_aliceDepositsThenGetsCapitalCalledThenDepositsAgain() public {
        // Arrange
        _allowlistInvestor(alice);

        // Act
        _commitInvestments(alice, 1 ether);
        _capitalCall(1 ether);

        // Assert
        assertEq(
            fundManager.totalCommitted(), 0 ether, "Total committed should be 0 ether after the first capital call"
        );

        // Act
        _commitInvestments(alice, 1 ether);

        // Assert
        assertEq(
            fundManager.totalCommitted(), 1 ether, "Total committed should be 1 ether after alice's second deposit"
        );
        assertEq(fundManager.investorCount(), 1, "Investor count should be 1 after capital call");
    }

    // found in https://github.com/bulla-network/factoring-contracts/pull/99#discussion_r1871662429
    function test_skewedInsolvencyToEnsureArrayConsistency() public {
        // Arrange
        address[] memory investorsToAllow = new address[](3);
        investorsToAllow[0] = alice;
        investorsToAllow[1] = bob;
        investorsToAllow[2] = charlie;
        asset.mint(charlie, 1000 ether);
        _allowlistInvestors(investorsToAllow);

        // Act

        _commitInvestments(alice, 1 ether);
        _commitInvestments(bob, 2 ether);
        _commitInvestments(charlie, 3 ether);

        uint256 totalAmountCommitted = 6 ether;

        // both alice and charlie go insolvent
        _goInsolvent(alice);
        _goInsolvent(charlie);

        // 50% capital call
        uint256 amountToCall = 3 ether;
        uint256 expectedInsolventAmount = 4 ether;

        (uint256 totalAmountCalled,) = _capitalCall(amountToCall);
        // Assert
        assertEq(
            totalAmountCalled, (totalAmountCommitted - expectedInsolventAmount) / 2, "Total called should be 1 ether"
        );
        assertEq(fundManager.investorCount(), 1, "Investor count should be 1 after capital call");
        assertEq(fundManager.investors(0), bob, "Bob should be the only investor after capital call");
        assertEq(
            fundManager.totalCommitted(),
            6 ether - expectedInsolventAmount - totalAmountCalled,
            "Total committed should be 1 ether"
        );

        // clear out the fund
        (totalAmountCalled,) = _capitalCall(fundManager.totalCommitted());
        assertEq(fundManager.totalCommitted(), 0, "Total committed should be 0 after capital call");
        assertEq(totalAmountCalled, 1 ether, "Bob's last 1 eth should be called");
    }
}
