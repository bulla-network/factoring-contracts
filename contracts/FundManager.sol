// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBullaFactoring, Ownable} from "./interfaces/IBullaFactoring.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

///
interface IBullaFactoringFundManager {
    //
    //// ERRORS
    error Unauthorized();
    error BadERC20Allowance(uint256 actual);
    error BadInvestorParams();
    error CallTooHigh();

    //
    //// EVENTS
    event InvestorAllowlisted(address indexed investor, address indexed owner);
    event InvestorCommitment(address indexed investor, uint144 amount);
    event InvestorInsolvent(address indexed investor, uint256 amountRequested);
    event CapitalCallComplete(address[] investors, uint256 callAmount);

    //
    //// STUCTS
    struct CapitalCommitment {
        bool isAllowed;
        uint144 commitment;
    }

    struct CapitalCall {
        address investor;
        uint256 amount;
    }
}

/// @title A contract used to manage the `BullaFactoring` fund
/// @author @colinnielsen
/// @notice INVARIANTS
///     I1: totalCommitted === ∑ capitalCommitments.commitment
contract BullaFactoringFundManager is IBullaFactoringFundManager {
    //
    //// IMMUTABLES
    IERC4626 public immutable factoringPool;
    IERC20 public immutable asset;
    uint256 public immutable minInvestment;

    //
    //// STATE
    uint224 public totalCommitted;
    uint32 public investorCount;
    mapping(address => CapitalCommitment) public capitalCommitments;

    constructor(IERC4626 _factoringPool, uint256 _minInvestment) {
        factoringPool = _factoringPool;
        asset = IERC20(_factoringPool.asset());
        minInvestment = _minInvestment;
    }

    /*
     *
     * ** CONTACT METHODS BY LIFECYCLE **
     *
     */

    /// @notice allows the fund manager to allow an investor to call the `invest` function at their own discretion
    /// @dev SPEC:
    /// lets the fund manager mark an investor address as allowlisted
    /// This function will:
    ///     RES1: set the `isAllowed` flag on the `capitalCommitments` mapping to true
    ///     RES2: `investorCount` is incremented
    ///     RES3: emit an `InvestorAllowlisted` event with the investor address and the current owner
    /// GIVEN:
    ///     S1: the `msg.sender` is the current owner on the `factoringPool` contract
    function allowlistInvestor(address investor) public {
        _onlyOwner(); // S1

        capitalCommitments[investor].isAllowed = true; // RES1
        ++investorCount; // RES2

        emit InvestorAllowlisted({investor: investor, owner: msg.sender}); // RES3
    }

    /// @notice allows an investor to commit to a certain `amount` of capital to a fund
    /// @dev SPEC:
    /// This function will:
    ///     RES1: set the `msg.sender`'s `capitalCommitments` struct to `amount`
    ///     RES2: increment the `totalCommited` storage by `amount`
    ///     RES3: emit an `InvestorCommitment` event with the commitment amount
    /// GIVEN:
    ///     S1: the `msg.sender` is marked as `allowed` on their capital commitment struct - as marked by the admin
    ///     S2: the `msg.sender`'s ERC20 allowance of this contract is >= their commitment `amount`
    ///     S3: `amount` <= type(uint144).max
    function commit(uint256 amount) public {
        if (!capitalCommitments[msg.sender].isAllowed) revert Unauthorized(); // S1

        uint256 allowance = asset.allowance(msg.sender, address(this));
        if (allowance != amount) revert BadERC20Allowance({actual: allowance}); // S2

        capitalCommitments[msg.sender].commitment = uint144(amount); // RES1 // S3
        totalCommitted += uint224(amount); // RES2

        emit InvestorCommitment({investor: msg.sender, amount: uint144(amount)}); // RES3
    }

    /// @notice allows the fund manager to pull funds from investors and send their tokens to the pool
    /// @dev SPEC:
    /// This function will:
    ///     RES1: `deposit()` an amount of an investor's `commitment` of `asset` relative to `totalCommitted` into the `factoringPool`
    ///     RES2: decrement an investors `commitmentAmount` by their `amount` sent to the pool
    ///     RES3: decrement `totalCommitted` by the total amount of USDC sent to the pool
    ///     RES4: emit a `CapitalCall` event with the total of amount sent to the pool
    /// GIVEN:
    ///     S1: the `msg.sender` is the current owner on the `factoringPool` contract
    ///     S2: the `amount` param is <= the `totalCommitted`
    /// TODO
    function capitalCall(uint256 callAmount, address[] memory investors) public {
        _onlyOwner(); // S1

        uint256 _totalCommitted = totalCommitted;
        uint256 _investorCount = investorCount;
        uint256 actualCallAmount = 0;
        uint256 insolventAmount = 0;

        if (callAmount > _totalCommitted) revert CallTooHigh();
        if (investors.length != _investorCount) revert BadInvestorParams();

        uint256 relativePercentageBPS = callAmount * 10_000 / _totalCommitted;

        asset.approve({spender: address(factoringPool), value: callAmount});

        for (uint256 i; i < investors.length; i++) {
            address investor = investors[i];

            CapitalCommitment memory cc = capitalCommitments[investor];
            if (!cc.isAllowed) revert BadInvestorParams();

            uint256 amountDue = uint256(cc.commitment) * relativePercentageBPS / 10_000;

            /// @dev will NOT revert
            bool success = _attemptERC20Transfer({from: investor, amount: amountDue});

            if (success) {
                factoringPool.deposit({assets: amountDue, receiver: investor});
                actualCallAmount += amountDue;
            } else {
                delete capitalCommitments[investor];
                insolventAmount += amountDue;

                emit InvestorInsolvent({investor: investor, amountRequested: amountDue});
            }
        }

        totalCommitted -= uint224(insolventAmount + callAmount);
        emit CapitalCallComplete({investors: investors, callAmount: actualCallAmount});
    }

    function blocklistInvestor(address _investor) public {
        // _onlyOwner();
    }

    ///
    ////// UTILITY / VIEW FUNCTIONS
    ///

    function getMaxCapitalCall(address[] memory callees) public view returns (uint256 withdrawable) {
        for (uint256 i; i < callees.length; i++) {
            address investor = callees[i];
            uint256 commitment = uint256(capitalCommitments[investor].commitment);
            uint256 allowance = asset.allowance(investor, address(this));

            if (allowance < commitment) continue;
            else withdrawable += commitment;
        }

        return withdrawable;
    }

    function _mathMin(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _onlyOwner() internal view {
        if (Ownable(address(factoringPool)).owner() != msg.sender) revert Unauthorized();
    }

    /**
     * @dev will attempt to execute a transferfrom and use the parsed success bool return var as the return
     * @dev will NOT revert, on external call, will simply return false
     */
    function _attemptERC20Transfer(address from, uint256 amount) internal returns (bool success) {
        try asset.transferFrom({from: from, to: address(this), value: amount}) returns (bool xferSuccess) {
            success = xferSuccess;
        } catch (bytes memory) {}
    }
}
