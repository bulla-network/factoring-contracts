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

contract Handler is StdCheats, CommonBase, StdUtils {
    BullaFactoringFundManager private target;
    MockUSDC private usdc;
    address[] private actors;
    address internal currentActor;

    // GHOST VARIALBES
    //
    uint256 public ghost_totalCommitted;

    constructor(BullaFactoringFundManager manager) {
        target = manager;
        usdc = MockUSDC(address(target.asset()));

        for (uint256 i; i < 10; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked(i)))));
            vm.label(actor, string.concat("[ACTOR #", vm.toString(i + 1), "]"));
            // allowlist all 10 investors
            vm.prank(target.owner());
            target.allowlistInvestor({investor: actor});

            actors.push(actor);
        }
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function deposit(uint256 _amount, uint256 actorIndexSeed) public useActor(actorIndexSeed) {
        uint256 amount = bound(_amount, target.minInvestment(), type(uint144).max);
        // get some asset
        usdc.mint({to: currentActor, amount: amount});
        // approve the fundManager
        usdc.approve(address(target), amount);
        // commit some funds
        target.commit({amount: amount});

        // update ghost vars
        ghost_totalCommitted += amount;
    }
}

contract FactoringFundInvariantTest is CommonSetup {
    BullaFactoringFundManager private fundManager;
    Handler private handler;

    function setUp() public override {
        super.setUp();

        fundManager = new BullaFactoringFundManager({
            _factoringPool: IERC4626(bullaFactoring),
            _minInvestment: 10e6,
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
    function invariant_isTrue() public {
        assertEq(fundManager.totalCommitted(), handler.ghost_totalCommitted());
    }
}
