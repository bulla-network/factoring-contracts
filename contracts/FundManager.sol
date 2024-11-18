// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBullaFactoring, Ownable} from "./interfaces/IBullaFactoring.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

///
interface IBullaFactoringFundManager {
    //
    //// ERRORS
    error Unauthorized();
    error BadERC20Allowance(uint256 actual);
    error CallTooHigh();

    //
    //// EVENTS
    event InvestorAllowlisted(address indexed investor, address indexed owner);
    event InvestorCommitment(address indexed investor, uint144 amount);
    event InvestorInsolvent(address indexed investor, uint256 amountRequested);

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
///     I1: totalComitted === ∑ capitalCommitments.commitment
contract BullaFactoringFundManager is IBullaFactoringFundManager {
    //
    //// IMMUTABLES
    IBullaFactoring public immutable factoringPool;
    IERC20 public immutable asset;

    //
    //// STATE
    uint256 public totalComitted;
    mapping(address => CapitalCommitment) public capitalCommitments;
    address[] public investors;

    constructor(IBullaFactoring _factoringPool) {
        factoringPool = _factoringPool;
        asset = _factoringPool.assetAddress();
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
    ///     RES2: add `investor` to the `investors` array
    ///     RES3: emit an `InvestorAllowlisted` event with the investor address and the current owner
    /// GIVEN:
    ///     S1: the `msg.sender` is the current owner on the `factoringPool` contract
    function allowlistInvestor(address investor) public {
        _onlyOwner(); // S1

        capitalCommitments[investor].isAllowed = true; // RES1
        investors.push(investor); // RES2

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
        totalComitted += amount; // RES2

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
    ///     S2: the `amount` param is <= the `totalComitted`
    ///     S3: an investor's `asset` aproval >= `callee[i]`'s stored `commitment` in the `capitalCommitments` mapping
    ///         --> otherwise:
    ///         S3.R1: their commitment is zeroed
    ///         S3.R2: `totalCommitments` is decremented by their commitment amount
    ///         S3.R3: a `InvestorInsolvent()` event is emitted with the address of the investor
    function capitalCall(uint256 amount) public {
        _onlyOwner(); // S1
        uint256 _totalComitted = totalComitted;
        uint256 amountToBeDeducted;
        if (amount > _totalComitted) revert CallTooHigh();
        uint256 relativePercentageBPS = amount * 10_000 / _totalComitted;

        address[] memory investorsList = investors;

        for (uint256 i; i < investorsList.length; i++) {
            address investor = investorsList[i];
            CapitalCommitment memory commitment = capitalCommitments[investor];
            uint256 relativeAmount = uint256(commitment.commitment) * relativePercentageBPS / 10_000;
            bool success;
            try asset.transferFrom({from: investor, to: address(this), value: relativeAmount}) returns (bool) {
                success = true;
            } catch Error(string memory) /*reason*/ {
                // This is executed in case
                // revert was called inside getData
                // and a reason string was provided.
            } catch Panic(uint256) /*errorCode*/ {
                // This is executed in case of a panic,
                // i.e. a serious error like division by zero
                // or overflow. The error code can be used
                // to determine the kind of error.
            } catch (bytes memory) /*lowLevelData*/ {
                // This is executed in case revert() was used.
            }

            if (!success) {
                delete capitalCommitments[investor];
                amountToBeDeducted -= relativeAmount;

                emit InvestorInsolvent({investor: investor, amountRequested: relativeAmount});
            } else {
                // factoringPool.deposit
            }
        }
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
}
