// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CommonBase, Vm} from "forge-std/Base.sol";
import {console} from "forge-std/console.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {BullaFactoringFundManager, IBullaFactoringFundManager} from "contracts/FactoringFundManager.sol";
import {CommonSetup, MockUSDC} from "../CommonSetup.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// max deposit is 100 mil USDC
uint256 constant MAX_DEPOSIT = 100_000_000 * 1e6;

//
//// @dev this contract will route all calls to the BullaFactoringFundManager
//
contract Handler is StdCheats, CommonBase, StdUtils {
    BullaFactoringFundManager private target;
    MockUSDC private usdc;
    address[] private investors;
    address internal currentInvestor;
    mapping(address => uint256) internal commitments;

    //// GHOST VARIALBES
    //
    uint256 public ghost_totalCapitalCalled;
    uint256 public ghost_totalInvestors;
    address public ghost_owner;
    address public ghost_capitalCaller;
    uint256 public ghost_minInvestment;
    bool public ghost_isPaused;

    //// SET UP
    //
    constructor(BullaFactoringFundManager manager) {
        target = manager;
        usdc = MockUSDC(address(target.asset()));

        ghost_owner = target.owner();
        ghost_capitalCaller = target.capitalCaller();
        ghost_minInvestment = target.minInvestment();

        uint256 investorCount = bound(vm.randomUint(), 3, 20);

        for (uint256 i; i < investorCount; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked(i)))));
            vm.label(actor, string.concat("[ACTOR #", vm.toString(i + 1), "]"));
            // allowlist all 10 investors
            vm.prank(target.owner());
            target.allowlistInvestor({investor: actor});

            ghost_totalInvestors++;
            investors.push(actor);
        }
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentInvestor = investors[bound(actorIndexSeed, 0, investors.length - 1)];
        vm.startPrank(currentInvestor);
        _;
        vm.stopPrank();
    }

    ///
    //// The invariant test will call all the following functions as "user scenarios" in randomized order, and assert the below FactoringFundInvariantTest.invariant assertions
    ////    this test suite attempts to ensure that regardless of:
    ////      - the amount of investors
    ////      - if an investor has been blocklisted
    ////      - any capital calls
    ////      - any ownership transfer
    ////      - any investor insolvency
    ////      - any min investment changes
    ////      THAT:
    ////      - I1: the total amount of capital committed is equal to the amount committed by `n` investor
    ////      - non-related variables stay consistent
    ////
    //// See the invariant_* functions below
    function investorDeposits(uint256 _amount, uint256 actorIndexSeed) public useActor(actorIndexSeed) {
        // if the investor has been blocklisted, ignore
        (bool isAllowed,) = target.capitalCommitments(currentInvestor);
        if (!isAllowed) return;

        // if the fund manager is paused, ignore
        if (ghost_isPaused) return;

        uint256 amount = bound(_amount, target.minInvestment(), MAX_DEPOSIT);
        // get some asset
        usdc.mint({to: currentInvestor, amount: amount});
        // approve the fundManager
        usdc.approve(address(target), amount);
        // commit some funds
        target.commit({amount: amount});

        // update ghost vars
        commitments[currentInvestor] = amount;
    }

    function userGoesInsolvent(uint256 actorIndexSeed) public useActor(actorIndexSeed) {
        // if the investor has already been blocklisted, ignore
        (bool isAllowed,) = target.capitalCommitments(currentInvestor);
        if (!isAllowed) return;

        // they run out of USDC
        usdc.transfer(address(0xdead), usdc.balanceOf(currentInvestor));
    }

    function ownerCapitalCalls(uint256 _amount) public {
        // if there have been no capital calls, ignore
        uint256 totalCommitted = target.totalCommitted();
        if (totalCommitted == 0) return;

        // ensure the amount is less than ghost total
        uint256 amount = bound(_amount, 0, totalCommitted);

        vm.prank(target.capitalCaller());
        (, uint256 insolventInvestorsCount) = target.capitalCall({targetCallAmount: amount});

        ghost_totalInvestors -= insolventInvestorsCount;
    }

    function ownerTransfersOwnership(address newOwner) public {
        if (newOwner == address(0)) return;

        vm.prank(target.owner());
        target.transferOwnership({newOwner: newOwner});

        // update ghost vars
        ghost_owner = newOwner;
    }

    function ownerSetsCapitalCaller(address newCapitalCaller) public {
        vm.prank(target.owner());
        target.setCapitalCaller({_capitalCaller: newCapitalCaller});

        // update ghost vars
        ghost_capitalCaller = newCapitalCaller;
    }

    function ownerSetsMinInvestment(uint256 newMinInvestment) public {
        // 1c < minInvestment < $1,000
        uint256 minInvestment = bound(newMinInvestment, 1e4, 1e9);
        vm.prank(target.owner());
        target.setMinInvestment({_minInvestment: minInvestment});

        // update ghost vars
        ghost_minInvestment = minInvestment;
        ghost_isPaused = false;
    }

    function ownerPausesCommitments() public {
        vm.prank(target.owner());
        target.pauseCommitments();

        ghost_minInvestment = target.minInvestment();
        // update ghost vars
        ghost_isPaused = true;
    }

    function ownerBlocklistsInvestor(uint256 investorSeed) public {
        address investor = investors[bound(investorSeed, 0, investors.length - 1)];

        // if the investor has already been blocklisted, ignore
        (bool isAllowed,) = target.capitalCommitments(investor);
        if (!isAllowed) return;

        vm.prank(target.owner());
        target.blocklistInvestor({_investor: investor});

        ghost_totalInvestors--;
    }
}

//
//// INVARIANT TEST
////
contract FactoringFundManagerInvariantTest is CommonSetup {
    BullaFactoringFundManager private fundManager;
    Handler private handler;

    function setUp() public override {
        super.setUp();

        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(address(vault)),
            _minInvestment: 1e6,
            _capitalCaller: address(this)
        });
        handler = new Handler(fundManager);

        vm.prank(fundManager.owner());
        depositPermissions.allow(address(fundManager));

        targetContract(address(handler));
    }

    /// forge-config: default.fuzz.show-logs = false
    /// forge-config: default.fuzz.fail-on-revert = true
    function invariant_I1() public view {
        uint256 currentCommitments;
        for (uint256 i; i < fundManager.investorCount(); ++i) {
            (, uint144 commitment) = fundManager.capitalCommitments(fundManager.investors(i));
            currentCommitments += uint256(commitment);
        }

        // I1: ensure the total committed on the manager is equal to the addition of all the capital commitments = the total amount capital called
        assertEq(fundManager.totalCommitted(), currentCommitments, "Total commitment invariant failed");
    }

    // function invariant_I2() public {
    //     // I2: BullaFactoringFundManager.totalCommitted amount of tokens can always be sent to the pool
    //     uint256 totalCommitted = fundManager.totalCommitted();
    //     uint256 poolBalanceBefore = asset.balanceOf(address(bullaFactoring));
    //     // snapshot evm state
    //     uint256 snapid = vm.snapshotState();

    //     vm.prank(fundManager.owner());
    //     fundManager.capitalCall({targetCallAmount: totalCommitted});

    //     uint256 poolBalanceAfter = asset.balanceOf(address(bullaFactoring));
    //     assertEq(poolBalanceAfter, totalCommitted, "Pool balance invariant failed");

    //     // revert the state
    //     vm.revertToStateAndDelete(snapid);
    // }

    /// forge-config: default.fuzz.fail-on-revert = true
    function invariant_variableConsistency() public view {
        assertEq(fundManager.investorCount(), handler.ghost_totalInvestors(), "Investor count should be equal");

        // each investor is allowed if they're in the investor array
        for (uint256 i; i < fundManager.investorCount(); ++i) {
            address investor = fundManager.investors(i);
            (bool isAllowed,) = fundManager.capitalCommitments(investor);
            assertEq(isAllowed, true, "Investor should be allowed");
        }

        assertEq(fundManager.minInvestment(), handler.ghost_minInvestment(), "Min investment should be consistent");
        assertEq(fundManager.capitalCaller(), handler.ghost_capitalCaller(), "Capital caller should be consistent");
        assertEq(fundManager.owner(), handler.ghost_owner(), "Owner should be consistent");
    }

    /// forge-config: default.fuzz.fail-on-revert = true
    function invariant_envConsistency() public view {
        assertEq(asset.balanceOf(address(fundManager)), 0, "FundManager should have no balance");
    }
}
