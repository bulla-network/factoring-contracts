// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {console} from "forge-std/console.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {BullaFactoringFundManager} from "contracts/FundManager.sol";
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

    // GHOST VARIALBES
    //
    uint256 public ghost_totalCapitalCalled;

    function ghost_totalCommitted() public view returns (uint256) {
        uint256 total;
        for (uint256 i; i < investors.length; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked(i)))));
            total += commitments[actor];
        }

        return total;
    }

    constructor(BullaFactoringFundManager manager) {
        target = manager;
        usdc = MockUSDC(address(target.asset()));

        uint256 investorCount = bound(vm.randomUint(), 3, 20);

        for (uint256 i; i < investorCount; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked(i)))));
            vm.label(actor, string.concat("[ACTOR #", vm.toString(i + 1), "]"));
            // allowlist all 10 investors
            vm.prank(target.owner());
            target.allowlistInvestor({investor: actor});

            investors.push(actor);
        }
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentInvestor = investors[bound(actorIndexSeed, 0, investors.length - 1)];
        vm.startPrank(currentInvestor);
        _;
        vm.stopPrank();
    }

    function deposit(uint256 _amount, uint256 actorIndexSeed) public useActor(actorIndexSeed) {
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

    // function goInsolvent

    function capitalCall(uint256 _amount) public {
        uint256 totalCommitted = target.totalCommitted();
        if (totalCommitted == 0) return;

        // ensure the amount is less than ghost total
        uint256 amount = bound(_amount, 0, totalCommitted);
        vm.prank(target.owner());
        target.capitalCall({targetCallAmount: amount});

        // update ghost vars
        ghost_totalCapitalCalled += amount;
    }
}

contract FactoringFundInvariantTest is CommonSetup {
    BullaFactoringFundManager private fundManager;
    Handler private handler;

    function setUp() public override {
        super.setUp();

        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(bullaFactoring),
            _minInvestment: 1e6,
            _capitalCaller: address(this)
        });
        handler = new Handler(fundManager);

        vm.prank(fundManager.owner());
        depositPermissions.allow(address(fundManager));

        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 10
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allInvariants() public {
        uint256 currentCommitments;
        for (uint256 i; i < fundManager.investorCount(); ++i) {
            (, uint144 commitment) = fundManager.capitalCommitments(fundManager.investors(i));
            currentCommitments += uint256(commitment);
        }

        // I1 (internal sanity check): ensure the total committed on the contract is what was tallied on the handler
        // assertEq(fundManager.totalCommitted(), handler.ghost_totalCommitted());
        // I1 (actual): ensure the total committed on the manager is equal to the addition of all the capital commitments = the total amount capital called
        assertEq(fundManager.totalCommitted(), currentCommitments);
    }
}
