// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IBullaFactoring, Ownable} from "./interfaces/IBullaFactoring.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// INTERFACE
////
interface IBullaFactoringFundManager {
    //
    //// ERRORS
    error Unauthorized();
    error BadERC20Allowance(uint256 actual);
    error BadERC20Balance(uint256 actual);
    error BadInvestorParams();
    error CallTooHigh();
    error CommitmentTooLow();
    error CommitmentTooHigh();
    error CannotRenounceOwnership();

    //
    //// EVENTS
    event InvestorAllowlisted(address indexed investor, address indexed owner);
    event InvestorCommitment(address indexed investor, uint256 amount);
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
/// @dev IMPORTANT!: This contract uses ERC20 allowances for it's internal accounting
///      This allows for investors to hold their assets, allowing for more capital efficiency.
///      !! This means that this contract will _not_ work with "fee on transfer"-type tokens, as the amount finally transferred should equal the allowance !!
/// @notice INVARIANTS
///     I1: totalCommitted === ( ∑ capitalCommitments.commitment - ∑ capitalCall's `callAmount` parameter )
contract BullaFactoringFundManager is IBullaFactoringFundManager, Ownable {
    //
    //// IMMUTABLES
    IERC4626 public immutable factoringPool;
    IERC20 public immutable asset;
    /// @dev represents "one" of whatever `asset` is:
    ///      example: `1e6` for USDC = 1 USDC
    ///      example: `1e18` for WETH = 1 WETH
    uint256 immutable ASSET_DENOMINATION;

    //
    //// STATE
    ///

    /// @notice a privileged address that can call the _capitalCall() function
    address public capitalCaller;
    /// @notice the mininum amount of `asset` - ideally denominated in `ASSET_DENOMINATION` - that an investor need to commit to
    uint256 public minInvestment;
    /// @notice the total amount of committed `asset` committed to the pool
    /// @dev will be decremented as capital calls occur
    uint256 public totalCommitted;
    /// @notice an array of investor addresses
    address[] public investors;
    // TODO @bengobeil: discuss if the following two storage slots are using an inefficient data structure. Why not use an array of CapitalCommitment structs?
    /// @notice a mapping of investor addresses to their capital commitment struct
    mapping(address => CapitalCommitment) public capitalCommitments;

    constructor(IERC4626 _factoringPool, uint256 _minInvestment, address _capitalCaller) Ownable(msg.sender) {
        // Set immutables
        factoringPool = _factoringPool;
        asset = IERC20(_factoringPool.asset());
        ASSET_DENOMINATION = 10 ** uint256(asset.decimals());
        // Set the state variables
        capitalCaller = _capitalCaller;
        minInvestment = _minInvestment;
    }

    /*
     *
     * ** CONTACT METHODS BY LIFECYCLE **
     *
     */

    /// @notice allows the fund manager to allow an investor to call the `invest` function at their own discretion
    /// @dev SPEC:
    /// This function will:
    ///     E1: set the `isAllowed` flag on the `capitalCommitments` mapping to true
    ///     E2: push the `investor` to the `investors` array if not already present
    ///     E3: emit an `InvestorAllowlisted` event with the investor address and the current owner
    /// GIVEN:
    ///     C1: the `msg.sender` is the current owner on the `factoringPool` contract
    function allowlistInvestor(address investor) public {
        _onlyOwner(); // C1

        if (!capitalCommitments[investor].isAllowed) {
            capitalCommitments[investor].isAllowed = true; // E1
            investors.push(investor); // E2
            emit InvestorAllowlisted({investor: investor, owner: msg.sender}); // E3
        }
    }

    /// @notice allows an investor to set their commitment to `amount` in the fund
    /// @notice allows active investors to update their commitment amount
    /// @dev SPEC:
    /// This function will:
    ///     E1: set the `msg.sender`'s `capitalCommitments` struct to `amount`
    ///     E2: increment the `totalCommitted` storage by `amount`
    ///     E3: emit an `InvestorCommitment` event with the commitment amount and investor
    /// GIVEN:
    ///     C1: the `msg.sender` is marked as `isAllowed` on their capital commitment struct - as marked by the admin in `allowlistInvestor`
    ///     C2: `amount` <= type(uint144).max
    ///     C3: their investment at least meets the mininum investment requirements
    ///     C4: the `msg.sender`'s ERC20 allowance of this contract is >= their commitment `amount`
    ///     C5: the `msg.sender` has a balance of `asset` >= their commitment `amount`
    function commit(uint256 amount) public {
        CapitalCommitment memory prevCC = capitalCommitments[msg.sender];
        uint256 totalCommittedBefore = totalCommitted;

        //// CHECKS:
        ///
        // C1
        if (prevCC.isAllowed == false) revert Unauthorized();
        // C2
        if (amount > type(uint144).max) revert CommitmentTooHigh();
        // C3
        if (amount < minInvestment) revert CommitmentTooLow();
        // C4
        uint256 allowance = asset.allowance(msg.sender, address(this));
        if (allowance < amount) revert BadERC20Allowance({actual: allowance});
        // C5
        uint256 balance = asset.balanceOf(msg.sender);
        if (balance < amount) revert BadERC20Balance({actual: balance});

        //// EFFECTS:
        ///

        //  COMMITMENT MODIFICATION FLOW: decrement totalCommittedBefore, essentally "undoing" their commitment from global commitments until E2
        //      (should not underflow because an individual's commitment will never be more than `totalCommitment` (see: I1))
        if (prevCC.commitment > 0) totalCommittedBefore = totalCommittedBefore - prevCC.commitment;

        // E1
        capitalCommitments[msg.sender].commitment = uint144(amount);
        // E2
        totalCommitted = totalCommittedBefore + uint224(amount);

        // E3
        emit InvestorCommitment({investor: msg.sender, amount: amount});
    }

    /// @notice allows the fund manager to pull funds from investors and send their tokens to the pool

    // TODO: IGNORE THIS!
    /// @dev SPEC:
    /// This function will:
    ///     E1: `deposit()` an amount of an investor's `commitment` of `asset` relative to `totalCommitted` into the `factoringPool`
    ///     E2: decrement an investors `commitmentAmount` by their `amount` sent to the pool
    ///     E3: decrement `totalCommitted` by the total amount of USDC sent to the pool
    ///     E4: emit a `CapitalCall` event with the total of amount sent to the pool
    /// GIVEN:
    ///     C1: the `msg.sender` is marked as the `capitalCaller`
    ///         C1.A: OR: msg.sender is the current owner on the `factoringPool` contract
    ///     C2: the `amount` param is <= the `totalCommitted`
    function capitalCall(uint256 targetCallAmount) public returns (uint256) {
        _onlyCapitalCaller(); // C1 // C1.A

        // load both the totalCommitted amount and investors array into memory
        uint256 _totalCommitted = totalCommitted;
        address[] memory _investors = investors;
        if (targetCallAmount > _totalCommitted) revert CallTooHigh();

        // keep track of a total call amount as the actual amount pulled into the pool
        // _may_ be less than `targetCallAmount` due to rounding errors
        uint256 totalAmountCalled = 0;
        uint256 insolventAmount = 0;

        // the relative amount is the amount of USDC to be pulled from the investor relative to the total committed amount
        // e.g. if the total committed is $100, and I capital call $50, that means I'm doing a 50% call
        //      so given alice's commitment of $30, and bob's of $70, they will both contribute $15 and $35 respectively
        //      this number would represent "50%" but in ASSET_DENOMINATION to help with rounding
        uint256 amountDueRatio = targetCallAmount * ASSET_DENOMINATION / _totalCommitted;

        uint256[] memory insolventInvestorsIndexes = new uint256[](_investors.length);
        uint256 insolventInvestorsCount = 0;

        // approve the factoring pool to pull `targetCallAmount` worth of `asset` from `this` contract's balance
        asset.approve({spender: address(factoringPool), amount: targetCallAmount});

        for (uint256 i; i < _investors.length; ++i) {
            address investor = _investors[i];

            CapitalCommitment memory cc = capitalCommitments[investor];
            if (!cc.isAllowed) continue;

            uint256 amountDue = uint256(cc.commitment) * amountDueRatio / ASSET_DENOMINATION;

            /// @dev will NOT revert
            bool withdrawalSuccess = _attemptERC20Transfer({from: investor, amount: amountDue});

            if (withdrawalSuccess) {
                factoringPool.deposit({assets: amountDue, receiver: investor});
                capitalCommitments[investor].commitment -= uint144(amountDue);
                totalAmountCalled += amountDue;
            } else {
                // if the withdrawal fails, delete the investor from this contract, and emit an event marking them solvent
                // insolventAmount += amountDue;
                insolventInvestorsIndexes[insolventInvestorsCount++] = i;
                emit InvestorInsolvent({investor: investor, amountRequested: amountDue});
            }
        }

        // delete the insolvent investors from the investors array
        for (uint256 i = insolventInvestorsCount; i > 0; i--) {
            _deleteInvestor({
                investor: _investors[insolventInvestorsIndexes[i - 1]],
                index: insolventInvestorsIndexes[i - 1]
            });
        }

        totalCommitted -= (totalAmountCalled + insolventAmount);
        emit CapitalCallComplete({investors: _investors, callAmount: totalAmountCalled});

        return totalAmountCalled;
    }

    /// @notice allows the fund manager to blocklist an investor, preventing them from commiting
    function blocklistInvestor(address _investor) public {
        _onlyOwner();

        uint256 investorCount = investors.length;
        for (uint256 i; i < investorCount; i++) {
            if (investors[i] == _investor) {
                _deleteInvestor({investor: _investor, index: i});
                break;
            }
        }
    }

    //
    //// OWNER FUNCTIONS
    //

    /// @notice Allows the owner to update the minimum investment amount
    /// @dev Only callable by the owner of the factoringPool
    /// @param _minInvestment The new minimum investment amount
    function setMinInvestment(uint256 _minInvestment) external {
        _onlyOwner();
        minInvestment = _minInvestment;
    }

    /// @dev we do not allow the owner to renounce ownership
    function renounceOwnership() public pure override {
        revert CannotRenounceOwnership();
    }

    ///
    ////// UTILITY / VIEW FUNCTIONS
    ///

    /// @notice reads the amount of investors
    function investorCount() public view returns (uint256) {
        return investors.length;
    }

    /// @notice reads the investor array
    function getInvestors() public view returns (address[] memory) {
        return investors;
    }

    /// @dev deletes an investor from the capital commitment mapping.
    ///      also removes them from the investors array, leaving a gap
    ///      but replaces that investor with the last investor in the array
    ///      and calling `.pop()` to remove the now duplicate data, and decrement investors.length by 1
    function _deleteInvestor(address investor, uint256 index) internal {
        uint256 commitment = capitalCommitments[investor].commitment;

        delete capitalCommitments[investor];
        investors[index] = investors[investors.length - 1];
        investors.pop();

        totalCommitted -= commitment;
    }

    function _mathMin(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev checks if the caller is the owner of the factoring pool
    function _isOwner() internal view returns (bool) {
        return owner() == msg.sender;
    }

    /// @dev checks if the caller is the capital caller or the owner of the factoring pool
    function _onlyCapitalCaller() internal view {
        if (msg.sender != capitalCaller && !_isOwner()) revert Unauthorized();
    }

    /// @dev checks if the caller is the owner of the factoring pool
    function _onlyOwner() internal view {
        if (!_isOwner()) revert Unauthorized();
    }

    /**
     * @dev will attempt to execute a transferfrom and use the parsed success bool return var as the return
     * @dev will NOT revert, on external call, will simply return false
     */
    function _attemptERC20Transfer(address from, uint256 amount) internal returns (bool succeeded) {
        try asset.transferFrom({from: from, to: address(this), amount: amount}) returns (bool xferSuccess) {
            return xferSuccess;
        } catch (bytes memory) {
            return false;
        }
    }
}
