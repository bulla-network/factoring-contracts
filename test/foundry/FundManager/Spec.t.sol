// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BullaFactoringFundManager, IBullaFactoringFundManager} from "contracts/FactoringFundManager.sol";
import {CommonSetup} from "../CommonSetup.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract BaseFactoringFundManagerSpecTestSetup is CommonSetup, IBullaFactoringFundManager {
    BullaFactoringFundManager public fundManager;

    // Test accounts
    address public owner = address(0x1111111111111111111111111111111111111111);
    address public charlie = address(0x2222222222222222222222222222222222222222);
    address public capitalCaller = address(0x3333333333333333333333333333333333333333);

    function setUp() public override {
        super.setUp();

        // Deploy MockUSDC and assign it to the fundManager
        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(bullaFactoring),
            _minInvestment: 10e6,
            _capitalCaller: capitalCaller
        });
        fundManager.transferOwnership(owner);
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

    // Helper function to mint USDC to an investor
    function _mintUSDC(address investor, uint256 amount) internal {
        asset.mint(investor, amount);
    }

    // Helper function to approve USDC for the fund manager
    function _approveUSDC(address investor, uint256 amount) internal {
        vm.prank(investor);
        asset.approve(address(fundManager), amount);
    }

    // Helper function to commit investments for multiple investors
    function _commitInvestments(address investor, uint256 amount) internal {
        _mintUSDC(investor, amount);
        _approveUSDC(investor, amount);

        vm.prank(investor);
        fundManager.commit(amount);
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

    function _getRandomApprovedInvestor(uint256 seed) internal returns (address) {
        address investor = address(uint160(uint256(keccak256(abi.encodePacked(seed)))));
        vm.label(investor, string.concat("[INVESTOR #", vm.toString(seed + 1), "]"));
        (bool isAllowed,) = fundManager.capitalCommitments(investor);
        if (!isAllowed) _allowlistInvestor(investor);

        return investor;
    }
}

///
///// SPECS
/////

//
//// Fuzz Tests for `allowlistInvestor`
//
contract AllowlistInvestorSpecTest is BaseFactoringFundManagerSpecTestSetup {
    ///// @notice SPEC: E1, E2, E3 - Successfully allowlist an investor
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_AllowlistInvestor_Success(address investor) public {
        // Assume investor is not the owner to prevent self-allowlisting
        vm.assume(investor != owner);

        // Expect the InvestorAllowlisted event to be emitted
        vm.expectEmit(true, true, false, false);
        emit InvestorAllowlisted({investor: investor, owner: owner});

        // Allowlist the investor
        vm.prank(owner);
        fundManager.allowlistInvestor(investor);

        // Assert E1: isAllowed flag is set to true
        (bool isAllowed, uint144 commitment) = fundManager.capitalCommitments(investor);
        assertTrue(isAllowed, "Investor should be allowlisted");
        assertTrue(commitment == 0, "Commitment should be 0");

        // Assert E2: Investor is added to the investors array
        bool isInArray = false;
        address[] memory allInvestors = fundManager.getInvestors();
        for (uint256 i = 0; i < allInvestors.length; i++) {
            if (allInvestors[i] == investor) {
                isInArray = true;
                break;
            }
        }
        assertTrue(isInArray, "Investor should be in the investors array");
    }

    ///// @notice SPEC: C1 - Only owner can allowlist investors
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_AllowlistInvestor_AccessControl(address nonOwner, address investor) public {
        // Assume nonOwner is not the owner and not the zero address
        vm.assume(nonOwner != owner && nonOwner != address(0));

        // Start prank as non-owner
        vm.startPrank(nonOwner);

        // Expect revert due to unauthorized access
        vm.expectRevert(Unauthorized.selector);

        // Attempt to allowlist investor
        fundManager.allowlistInvestor(investor);

        vm.stopPrank();
    }

    ///// @notice SPEC: C2 - Cannot allowlist an already allowlisted investor
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_AllowlistInvestor_AlreadyAllowlisted(address investor) public {
        // Assume investor is not the owner
        vm.assume(investor != owner);

        vm.startPrank(owner);
        // First allowlist the investor
        fundManager.allowlistInvestor(investor);

        // Expect revert when trying to allowlist again
        vm.expectRevert(AlreadyAllowlisted.selector);

        // Attempt to allowlist the same investor again
        fundManager.allowlistInvestor(investor);

        vm.stopPrank();
    }
}

//
//// Fuzz Tests for `commit`
//
contract CommitSpecTest is BaseFactoringFundManagerSpecTestSetup {
    ///// @notice SPEC: E1, E2, E3 - Successfully commit an investment
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Commit_Success(uint256 amount) public {
        // Assume amount is within valid range
        vm.assume(amount >= fundManager.minInvestment());
        vm.assume(amount <= type(uint144).max);

        // Assume msg.sender is allowlisted
        address investor = _getRandomApprovedInvestor(1);

        // Mint and approve USDC before committing
        _mintUSDC(investor, amount);
        _approveUSDC(investor, amount);

        // Expect InvestorCommitment event
        vm.expectEmit(true, true, false, false);
        emit InvestorCommitment({investor: investor, amount: amount});

        vm.prank(investor);
        // Commit the amount
        fundManager.commit(amount);

        // Assert E1: commitment is set
        (bool isAllowed, uint144 commitment) = fundManager.capitalCommitments(investor);
        assertTrue(isAllowed, "Investor should be allowed");
        assertEq(commitment, amount, "Commitment should match the committed amount");

        // Assert E2: totalCommitted incremented
        uint256 total = fundManager.totalCommitted();
        assertEq(total, amount, "Total committed should equal the committed amount");

        // Assert E3: Event emitted
        // Already checked by expectEmit

        vm.stopPrank();
    }

    ///// @notice SPEC: C1 - Only allowlisted investors can commit
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Commit_AccessControl(address nonInvestor, uint256 amount) public {
        // Assume nonInvestor is not allowlisted
        vm.assume(nonInvestor != address(this) && nonInvestor != owner && nonInvestor != address(0));
        vm.assume(amount >= fundManager.minInvestment());
        vm.assume(amount <= type(uint144).max);

        // Mint and approve USDC before committing
        _mintUSDC(nonInvestor, amount);
        _approveUSDC(nonInvestor, amount);

        vm.startPrank(nonInvestor);
        // Expect revert due to unauthorized access
        vm.expectRevert(Unauthorized.selector);
        // Attempt to commit
        fundManager.commit(amount);

        vm.stopPrank();
    }

    ///// @notice SPEC: C2 - Cannot commit amount > uint144.max
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Commit_ExceedsMax(uint256 _amount) public {
        // Assume amount > uint144.max
        uint256 amount = bound(_amount, uint256(type(uint144).max) + 1, type(uint248).max);

        // Assume investor is allowlisted
        address investor = _getRandomApprovedInvestor(2);

        // Mint and approve USDC
        _mintUSDC(investor, amount);
        _approveUSDC(investor, amount);

        // Expect revert due to CommitmentTooHigh
        vm.expectRevert(CommitmentTooHigh.selector);

        vm.startPrank(investor);

        // Attempt to commit
        fundManager.commit(amount);

        vm.stopPrank();
    }

    ///// @notice SPEC: C3 - Cannot commit below minimum investment
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Commit_BelowMinimum(uint256 amount) public {
        // Assume amount < minInvestment
        vm.assume(amount < fundManager.minInvestment());

        // Assume investor is allowlisted
        address investor = _getRandomApprovedInvestor(3);

        _mintUSDC(investor, amount);
        _approveUSDC(investor, amount);

        // Expect revert due to CommitmentTooLow
        vm.expectRevert(CommitmentTooLow.selector);

        vm.startPrank(investor);

        // Attempt to commit
        fundManager.commit(amount);

        vm.stopPrank();
    }

    ///// @notice SPEC: C4 - Cannot commit without sufficient ERC20 allowance
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Commit_InsufficientAllowance(uint256 amount) public {
        // Assume amount >= minInvestment and <= uint144.max
        vm.assume(amount >= fundManager.minInvestment());
        vm.assume(amount <= type(uint144).max);

        // Assume investor is allowlisted
        address investor = _getRandomApprovedInvestor(4);

        // Mint USDC
        _mintUSDC(investor, amount);

        // Approve less than amount
        _approveUSDC(investor, amount - 1);

        // Expect revert due to BadERC20Allowance
        vm.expectRevert(abi.encodeWithSelector(BadERC20Allowance.selector, amount - 1));

        vm.startPrank(investor);
        // Attempt to commit
        fundManager.commit(amount);

        vm.stopPrank();
    }

    ///// @notice SPEC: C5 - Cannot commit without sufficient asset balance
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_Commit_InsufficientBalance(uint256 amount) public {
        // Assume amount >= minInvestment and <= uint144.max
        vm.assume(amount >= fundManager.minInvestment());
        vm.assume(amount <= type(uint144).max);

        // Assume investor is allowlisted
        address investor = _getRandomApprovedInvestor(5);

        // Mint less than the required amount
        _mintUSDC(investor, amount - 1);
        _approveUSDC(investor, amount);

        // Expect revert due to BadERC20Balance
        vm.expectRevert(abi.encodeWithSelector(BadERC20Balance.selector, amount - 1));

        vm.startPrank(investor);
        // Attempt to commit
        fundManager.commit(amount);

        vm.stopPrank();
    }
}

//
//// Fuzz Tests for `capitalCall`
//
contract CapitalCallSpecTest is BaseFactoringFundManagerSpecTestSetup {
    ///// @notice SPEC: E1, E2, E3, E4 + R1, R2 - Successfully execute a capital call
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_Success(uint256 _targetCallAmount) public {
        // Assume targetCallAmount is within valid range
        uint256 totalCommitted = 3000e6;
        uint256 targetCallAmount = bound(_targetCallAmount, 1, totalCommitted);

        // Setup: Allowlist investors and set their commitments
        address investor1 = _getRandomApprovedInvestor(1);
        address investor2 = _getRandomApprovedInvestor(2);
        _commitInvestments(investor1, 1000e6); // Investor1 commits 1,000 USDC
        _commitInvestments(investor2, 2000e6); // Investor2 commits 2,000 USDC

        uint256 amountDueRatio = targetCallAmount * 1e6 / totalCommitted;

        // Calculate expected amounts based on proportions
        uint256 expectedAmountCalledInvestor1 = (1000e6 * amountDueRatio) / 1e6; // SPEC: E2
        uint256 expectedAmountCalledInvestor2 = (2000e6 * amountDueRatio) / 1e6; // SPEC: E2

        // Expect CapitalCallComplete event
        vm.expectEmit(true, false, false, false);
        emit CapitalCallComplete({investors: new address[](2), callAmount: targetCallAmount}); // SPEC: E4

        // Execute capital call
        vm.prank(capitalCaller);
        (uint256 totalAmountCalled, uint256 insolventInvestorsCount) = fundManager.capitalCall(targetCallAmount);

        // Assertions
        assertEq(
            totalAmountCalled,
            expectedAmountCalledInvestor1 + expectedAmountCalledInvestor2,
            "Total amount called should match the additive expected amounts"
        ); // SPEC: R1
        assertEq(insolventInvestorsCount, 0, "No investors should be insolvent"); // SPEC: R2

        // Verify commitments are decremented correctly
        (bool isAllowed1, uint144 commitment1) = fundManager.capitalCommitments(investor1);
        (bool isAllowed2, uint144 commitment2) = fundManager.capitalCommitments(investor2);
        assertTrue(isAllowed1, "Investor1 should still be allowed"); // SPEC: E1
        assertTrue(isAllowed2, "Investor2 should still be allowed"); // SPEC: E1
        assertEq(
            commitment1,
            1000e6 - uint144(expectedAmountCalledInvestor1),
            "Investor1's commitment should be decremented correctly"
        ); // SPEC: E2
        assertEq(
            commitment2,
            2000e6 - uint144(expectedAmountCalledInvestor2),
            "Investor2's commitment should be decremented correctly"
        ); // SPEC: E2
    }

    ///// @notice SPEC: C1 - Only capitalCaller or owner can execute a capital call
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_AccessControl(address caller, uint256 _targetCallAmount) public {
        // Assume caller is neither capitalCaller nor owner
        vm.assume(caller != capitalCaller && caller != owner);

        // Setup: Allowlist an investor and set commitment
        address investor = _getRandomApprovedInvestor(1);
        _commitInvestments(investor, 1000e6);

        // Bind targetCallAmount within valid range
        uint256 targetCallAmount = bound(_targetCallAmount, 1, fundManager.totalCommitted());

        // Expect revert due to unauthorized access
        vm.expectRevert(IBullaFactoringFundManager.Unauthorized.selector); // SPEC: C1

        // Attempt to execute capital call as unauthorized caller
        vm.prank(caller);
        fundManager.capitalCall(targetCallAmount);
    }

    ///// @notice SPEC: C2 - targetCallAmount must be <= totalCommitted
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_ExceedsTotalCommitted(uint256 _targetCallAmount) public {
        // Setup: Allowlist investors and set their commitments
        address investor1 = _getRandomApprovedInvestor(1);
        address investor2 = _getRandomApprovedInvestor(2);
        _commitInvestments(investor1, 1000e6); // Investor1 commits 1,000 USDC
        _commitInvestments(investor2, 2000e6); // Investor2 commits 2,000 USDC

        // Assume targetCallAmount > totalCommitted
        uint256 targetCallAmount = bound(_targetCallAmount, fundManager.totalCommitted() + 1, type(uint144).max);

        // Expect revert due to CallTooHigh
        vm.expectRevert(IBullaFactoringFundManager.CallTooHigh.selector); // SPEC: C2

        // Execute capital call as capitalCaller
        vm.prank(capitalCaller);
        fundManager.capitalCall(targetCallAmount);
    }

    ///// @notice SPEC: E1.b - Handle insolvent investors during capital call
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_HandleInsolventInvestors(uint256 _targetCallAmount) public {
        // Setup: Allowlist multiple investors and set commitments
        address investor1 = _getRandomApprovedInvestor(1);
        address investor2 = _getRandomApprovedInvestor(2);
        address investor3 = _getRandomApprovedInvestor(3);
        _commitInvestments(investor1, 1000e6); // Investor1 commits 1,000 USDC
        _commitInvestments(investor2, 2000e6); // Investor2 commits 2,000 USDC
        _commitInvestments(investor3, 3000e6); // Investor3 commits 3,000 USDC

        // Total committed: 6,000 USDC
        uint256 totalCommitted = fundManager.totalCommitted();
        uint256 targetCallAmount = bound(_targetCallAmount, 3 * 1e6, totalCommitted);

        // Make investor2 insolvent by transferring all their assets
        _goInsolvent(investor2);

        uint256 amountDueRatio = targetCallAmount * 1e6 / totalCommitted;

        // Calculate expected amounts
        uint256 amountDue1 = (1000e6 * amountDueRatio) / 1e6; // SPEC: E2
        uint256 amountDue2 = (2000e6 * amountDueRatio) / 1e6; // SPEC: E2
        uint256 amountDue3 = (3000e6 * amountDueRatio) / 1e6; // SPEC: E2

        // Expect InvestorInsolvent event
        vm.expectEmit(true, false, false, false);
        emit InvestorInsolvent({investor: investor2, amountRequested: amountDue2}); // SPEC: E1.b

        address[] memory investors = fundManager.getInvestors();
        // Expect CapitalCallComplete event
        vm.expectEmit(false, false, false, false);
        emit CapitalCallComplete({investors: investors, callAmount: amountDue1 + amountDue3}); // SPEC: E4

        // Execute capital call as capitalCaller
        vm.prank(capitalCaller);
        (uint256 totalAmountCalled, uint256 insolventInvestorsCount) = fundManager.capitalCall(targetCallAmount);

        // Assertions
        assertEq(totalAmountCalled, amountDue1 + amountDue3, "Total amount called should exclude insolvent investors"); // SPEC: R1
        assertEq(insolventInvestorsCount, 1, "One investor should be insolvent"); // SPEC: R2

        // Verify commitments
        (bool isAllowed1, uint144 commitment1) = fundManager.capitalCommitments(investor1); // SPEC: E1
        (bool isAllowed2, uint144 commitment2) = fundManager.capitalCommitments(investor2); // SPEC: E1
        (bool isAllowed3, uint144 commitment3) = fundManager.capitalCommitments(investor3); // SPEC: E1
        assertTrue(isAllowed1, "Investor1 should still be allowed"); // SPEC: E1
        assertFalse(isAllowed2, "Investor2 should be blocklisted"); // SPEC: E1
        assertTrue(isAllowed3, "Investor3 should still be allowed"); // SPEC: E1
        assertEq(commitment1, 1000e6 - uint144(amountDue1), "Investor1's commitment should be decremented correctly"); // SPEC: E2
        assertEq(commitment2, 0, "Investor2's commitment should be reset"); // SPEC: E2
        assertEq(commitment3, 3000e6 - uint144(amountDue3), "Investor3's commitment should be decremented correctly"); // SPEC: E2
    }

    ///// @notice SPEC: E1.a - Handle multiple insolvent investors during capital call
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_MultipleInsolventInvestors(uint256 _targetCallAmount) public {
        // Setup: Allowlist multiple investors and set commitments
        address investor1 = _getRandomApprovedInvestor(1);
        address investor2 = _getRandomApprovedInvestor(2);
        address investor3 = _getRandomApprovedInvestor(3);

        uint256 investor1Commitment = 1000e6;
        uint256 investor2Commitment = 102400e6;
        uint256 investor3Commitment = 3000e6;
        _commitInvestments(investor1, investor1Commitment); // Investor1 commits 1,000 USDC
        _commitInvestments(investor2, investor2Commitment); // Investor2 commits 2,000 USDC
        _commitInvestments(investor3, investor3Commitment); // Investor3 commits 3,000 USDC

        // Total committed: 6,000 USDC
        uint256 totalCommitted = fundManager.totalCommitted();
        uint256 targetCallAmount = bound(_targetCallAmount, 3 * 1e6, totalCommitted);
        address[] memory investors = fundManager.getInvestors();

        // Make investor1 and investor3 insolvent
        _goInsolvent(investor1);
        _goInsolvent(investor3);

        uint256 amountDueRatio = targetCallAmount * 1e6 / totalCommitted;

        // Calculate expected amounts
        uint256 amountDue1 = (investor1Commitment * amountDueRatio) / 1e6; // SPEC: E2
        uint256 amountDue2 = (investor2Commitment * amountDueRatio) / 1e6; // SPEC: E2
        uint256 amountDue3 = (investor3Commitment * amountDueRatio) / 1e6; // SPEC: E2

        // Expect InvestorInsolvent events for investor1 and investor3
        vm.expectEmit(true, false, false, false);
        emit InvestorInsolvent({investor: investor1, amountRequested: amountDue1}); // SPEC: E1.a
        vm.expectEmit(true, false, false, false);
        emit InvestorInsolvent({investor: investor3, amountRequested: amountDue3}); // SPEC: E1.a

        // Expect CapitalCallComplete event
        vm.expectEmit(true, false, false, false);
        emit CapitalCallComplete({investors: investors, callAmount: amountDue2}); // SPEC: E4

        // Execute capital call as capitalCaller
        vm.prank(capitalCaller);
        (uint256 totalAmountCalled, uint256 insolventInvestorsCount) = fundManager.capitalCall(targetCallAmount);

        // Assertions
        assertEq(totalAmountCalled, amountDue2, "Total amount called should only include solvent investors"); // SPEC: R1
        assertEq(insolventInvestorsCount, 2, "Two investors should be insolvent"); // SPEC: R2

        // Verify commitments
        (bool isAllowed1, uint144 commitment1) = fundManager.capitalCommitments(investor1); // SPEC: E1.a
        (bool isAllowed2, uint144 commitment2) = fundManager.capitalCommitments(investor2); // SPEC: E1.a
        (bool isAllowed3, uint144 commitment3) = fundManager.capitalCommitments(investor3); // SPEC: E1.a

        assertFalse(isAllowed1, "Investor1 should be blocklisted"); // SPEC: E1.a
        assertTrue(isAllowed2, "Investor2 should still be allowed"); // SPEC: E1.a
        assertFalse(isAllowed3, "Investor3 should be blocklisted"); // SPEC: E1.a

        assertEq(commitment1, 0, "Investor1's commitment should be reset"); // SPEC: E2
        assertEq(
            commitment2,
            investor2Commitment - uint144(amountDue2),
            "Investor2's commitment should be decremented correctly"
        ); // SPEC: E2
        assertEq(commitment3, 0, "Investor3's commitment should be reset"); // SPEC: E2
    }

    ///// @notice SPEC: C3 - targetCallAmount must be greater than zero
    function test_CapitalCall_ZeroAmount() public {
        // Setup: Allowlist an investor and set commitment
        address investor = _getRandomApprovedInvestor(1);
        _commitInvestments(investor, 1000e6);

        // Execute capital call as capitalCaller
        vm.prank(capitalCaller);

        vm.expectRevert(IBullaFactoringFundManager.CallTooLow.selector);
        fundManager.capitalCall(0);
    }

    ///// @notice SPEC: C4 - Capital call with no investors
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_NoInvestors(uint256 targetCallAmount) public {
        // Ensure no investors are allowlisted
        assertEq(fundManager.investorCount(), 0, "There should be no investors allowlisted");

        // Execute capital call as capitalCaller
        vm.prank(capitalCaller);

        // reverts by division by zero
        vm.expectRevert();
        fundManager.capitalCall(targetCallAmount);
    }

    ///// @notice SPEC: C5 - Handling deletion with fuzzed index
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_CapitalCall_InsolventInvestorIndex(uint256 _targetCallAmount, uint8 _invalidIndex) public {
        uint256 targetCallAmount = bound(_targetCallAmount, 5 * 1e6, 15000e6);
        uint256 invalidIndex = bound(_invalidIndex, 0, 4);

        // Setup: Allowlist multiple investors and set commitments
        address investor1 = _getRandomApprovedInvestor(1);
        address investor2 = _getRandomApprovedInvestor(2);
        address investor3 = _getRandomApprovedInvestor(3);
        address investor4 = _getRandomApprovedInvestor(4);
        address investor5 = _getRandomApprovedInvestor(5);
        _commitInvestments(investor1, 1000e6); // Investor1 commits 1,000 USDC
        _commitInvestments(investor2, 2000e6); // Investor2 commits 2,000 USDC
        _commitInvestments(investor3, 3000e6); // Investor3 commits 3,000 USDC
        _commitInvestments(investor4, 4000e6); // Investor4 commits 4,000 USDC
        _commitInvestments(investor5, 5000e6); // Investor5 commits 5,000 USDC

        address[] memory investors = fundManager.getInvestors();

        // Total committed: 15,000 USDC
        uint256 totalCommitted = fundManager.totalCommitted();
        uint256 amountDueRatio = targetCallAmount * 1e6 / totalCommitted;

        // Make one investor insolvent based on fuzzed index
        address insolventInvestor = fundManager.investors(invalidIndex);
        (, uint144 commitment) = fundManager.capitalCommitments(insolventInvestor);
        uint256 amountRequestedByInsolventInvestor = (commitment * amountDueRatio) / 1e6;
        _goInsolvent(insolventInvestor);

        // Expect InvestorInsolvent event if insolvency is triggered
        vm.expectEmit(true, false, false, false);
        emit InvestorInsolvent({investor: insolventInvestor, amountRequested: amountRequestedByInsolventInvestor}); // SPEC: C5

        // Expect CapitalCallComplete event
        vm.expectEmit(true, false, false, false);
        emit CapitalCallComplete({
            investors: investors,
            callAmount: targetCallAmount - amountRequestedByInsolventInvestor
        }); // SPEC: E4

        // Execute capital call as capitalCaller
        vm.prank(capitalCaller);
        (uint256 totalAmountCalled, uint256 insolventInvestorsCount) = fundManager.capitalCall(targetCallAmount);

        // Assertions
        assertEq(insolventInvestorsCount, 1, "One investor should be insolvent"); // SPEC: R2
        assertLt(totalAmountCalled, targetCallAmount, "Total amount should be less than target call amount"); // SPEC: R1
    }
}

//
//// Fuzz Tests for Owner related functions
//
contract OwnerFunctionsSpecTest is BaseFactoringFundManagerSpecTestSetup {
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_SetMinInvestment(address notOwner, uint256 _minInvestment) public {
        vm.assume(notOwner != owner);

        // Non-authorized parties cannot set min
        vm.prank(notOwner);
        vm.expectRevert(IBullaFactoringFundManager.Unauthorized.selector);
        fundManager.setMinInvestment(_minInvestment);

        uint256 previousMinInvestment = fundManager.minInvestment();

        // Authorized parties can set min
        vm.prank(owner);
        if (_minInvestment == 0) {
            vm.expectRevert(IBullaFactoringFundManager.MinInvestmentTooLow.selector);
            fundManager.setMinInvestment(_minInvestment);
        } else {
            fundManager.setMinInvestment(_minInvestment);
            assertEq(fundManager.minInvestment(), _minInvestment, "Min investment should be set correctly");
        }

        // Authorized parties can reset min
        vm.prank(owner);
        fundManager.setMinInvestment(previousMinInvestment);
        assertEq(fundManager.minInvestment(), previousMinInvestment, "Min investment should be reset correctly");
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_SetCapitalCaller(address _capitalCaller) public {
        vm.assume(_capitalCaller != address(0) && _capitalCaller != owner);

        // non owners cannot set the capital caller
        vm.expectRevert(IBullaFactoringFundManager.Unauthorized.selector);
        fundManager.setCapitalCaller(_capitalCaller);

        // owners can set the capital caller
        vm.prank(owner);
        fundManager.setCapitalCaller(_capitalCaller);
        assertEq(fundManager.capitalCaller(), _capitalCaller, "Capital caller should be set correctly");
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_BlocklistInvestor(address _investor) public {
        _allowlistInvestor(_investor);
        _commitInvestments(_investor, 1000e6);

        // non owners cannot blocklist an investor
        vm.expectRevert(IBullaFactoringFundManager.Unauthorized.selector);
        fundManager.blocklistInvestor(_investor);

        // owners can blocklist an investor
        vm.prank(owner);
        fundManager.blocklistInvestor(_investor);
        (bool isAllowed, uint144 commitment) = fundManager.capitalCommitments(_investor);
        assertFalse(isAllowed, "Investor should be blocked");
        assertEq(commitment, 0, "Investor's commitment should be reset");
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_renounceOwnership(address _notOwner) public {
        vm.assume(_notOwner != owner);

        // non owners cannot renounce ownership
        vm.expectRevert(IBullaFactoringFundManager.CannotRenounceOwnership.selector);
        fundManager.renounceOwnership();

        // owners cannot renounce ownership either
        vm.prank(owner);
        vm.expectRevert(IBullaFactoringFundManager.CannotRenounceOwnership.selector);
        fundManager.renounceOwnership();
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_PauseCommitments(address _notOwner, uint256 _amountToCommit) public {
        vm.assume(_notOwner != owner);
        uint256 amountToCommit = bound(_amountToCommit, fundManager.minInvestment(), type(uint144).max);

        // non owners cannot pause
        vm.expectRevert(IBullaFactoringFundManager.Unauthorized.selector);
        vm.prank(_notOwner);
        fundManager.pauseCommitments();

        // owners can pause
        vm.prank(owner);
        fundManager.pauseCommitments();
        assertEq(fundManager.minInvestment(), type(uint256).max, "Min investment should be set to max");

        // no one can commit now
        address investor = _getRandomApprovedInvestor(1);

        _mintUSDC(investor, amountToCommit);
        _approveUSDC(investor, amountToCommit);

        vm.prank(investor);
        vm.expectRevert(IBullaFactoringFundManager.CommitmentTooLow.selector);
        fundManager.commit(amountToCommit);
    }
}
