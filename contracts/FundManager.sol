// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBullaFactoring} from "./interfaces/IBullaFactoring.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @Mike-Revy spec
 *  there will be capital calls every day
 *  capital calls happen by percentage (bob gets called by %50)
 */

///
interface IBullaFactoringFundManager {
    //
    //// ERRORS
    error Unauthorized();
    error ERC20UnderAllowed();

    //
    //// EVENTS
    event InvestorAllowlisted(address indexed investor, address indexed owner);
    event InvestorCommitment(address indexed investor, uint144 amount);

    //
    //// STUCTS
    struct CapitalCommitment {
        bool isAllowed;
        uint144 commitment;
    }
}

/// @title A contract used to manage the `BullaFactoring` fund
/// @author @colinnielsen
/// @notice
contract BullaFactoringFundManager is IBullaFactoringFundManager {
    IBullaFactoring public factoringPool;
    IERC20 public asset;

    mapping(address => CapitalCommitment) public capitalCommitment;

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
    ///   RES1: set the `isAllowed` flag on the `capitalCommitment` mapping to true
    ///   RES2: emit an `InvestorAllowlisted` event with the investor address and the current owner
    /// GIVEN:
    ///   S1: the `msg.sender` is the current owner on the `factoringPool` contract
    function allowlistInvestor(address investor) public {
        _onlyOwner(); // S1
        capitalCommitment[investor].isAllowed = true; // RES1

        emit InvestorAllowlisted(investor, msg.sender); // RES2
    }

    /// @notice allows an investor to commit to a certain `amount` of capital to a fund
    /// @dev SPEC:
    /// This function will:
    ///   RES1: set the `msg.sender`'s `capitalCommitment` struct to `amount`
    ///   RES2: emit an `InvestorCommitment` event with the commitment amount
    /// GIVEN:
    ///   S1: the `msg.sender` is marked as `allowed` on their capital commitment struct - as marked by the admin
    ///   S2: the `msg.sender`'s ERC20 allowance of this contract is >= their commitment `amount`
    function commit(uint256 amount) public {
        if (!capitalCommitment[msg.sender].isAllowed) revert Unauthorized(); // S1
        if (asset.allowance(msg.sender, address(this)) != amount) revert ERC20UnderAllowed(); // S2

        capitalCommitment[msg.sender].commitment = uint144(amount); // RES1

        emit InvestorCommitment(msg.sender, uint144(amount)); // RES2
    }

    /// @notice allows the fund manager to allow an investor to call the `invest` function at their own discretion
    /// @dev SPEC:
    /// lets the fund manager mark an investor address as allowlisted
    /// This function will:
    ///   RES1: set the `isAllowed` flag on the `capitalCommitment` mapping to true
    ///   RES2: emit an `InvestorAllowlisted` event with the investor address and the current owner
    /// GIVEN:
    ///   S1: the `msg.sender` is the current owner on the `factoringPool` contract
    function capitalCall() public {
        // _onlyOwner();
    }

    function blocklistInvestor(address _investor) public {
        // _onlyOwner();
    }

    ///
    ////// UTILITY / VIEW FUNCTIONS
    ///

    function _onlyOwner() internal view {
        if (factoringPool.owner() != msg.sender) revert Unauthorized();
    }
}
