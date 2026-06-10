// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { BullaFactoringV2_2 } from 'contracts/BullaFactoring.sol';
import { GhoBullaFacilitator } from 'contracts/GhoBullaFacilitator.sol';
import { MockGhoToken } from 'contracts/mocks/MockGhoToken.sol';
import { IGhoToken } from 'contracts/interfaces/IGhoToken.sol';
import "contracts/interfaces/IBullaFactoring.sol";
import { CreateClaimParams, ClaimBinding } from "bulla-contracts-v2/src/types/Types.sol";
import { CommonSetup } from './CommonSetup.t.sol';

contract TestGhoBullaFacilitator is CommonSetup {
    event Deposited(uint256 ghoDeposited, uint256 ghoMinted, uint256 sharesReceived);
    event Redeemed(uint256 sharesRedeemed, uint256 assetsReceivedImmediately);
    event GhoSettled(uint256 ghoBurned, uint256 yieldToTreasury);
    event GhoTreasuryUpdated(address indexed oldGhoTreasury, address indexed newGhoTreasury);

    MockGhoToken public gho;
    BullaFactoringV2_2 public ghoPool;
    GhoBullaFacilitator public facilitator;

    address ghoTreasury = address(0x7e4517);
    address ghoTreasuryAdmin = address(0xAD319);

    uint128 constant BUCKET_CAPACITY = 1_000_000e18;
    uint256 constant DEPOSIT_AMOUNT = 100_000e18;

    function setUp() public override {
        super.setUp();

        gho = new MockGhoToken();
        ghoPool = new BullaFactoringV2_2(
            IERC20(address(gho)),
            invoiceAdapterBulla,
            underwriter,
            depositPermissions,
            redeemPermissions,
            factoringPermissions,
            bullaDao,
            protocolFeeBps,
            adminFeeBps,
            'GHO Factoring Pool',
            targetYield,
            'Bulla GHO Factoring Pool Token',
            'BFT-GHO',
            address(0x1999),
            uint16(100),
            uint16(500),
            uint16(5000)
        );
        bullaClaim.addToPaidCallbackWhitelist(address(ghoPool), ghoPool.reconcileSingleInvoice.selector);

        // this test contract deploys the facilitator and is therefore its owner
        facilitator = new GhoBullaFacilitator(IGhoToken(address(gho)), IERC4626(address(ghoPool)), ghoTreasury, ghoTreasuryAdmin);

        // governance approves the facilitator with a bucket capacity
        gho.addFacilitator(address(facilitator), BUCKET_CAPACITY);
        // the test contract acts as a side facilitator to mint GHO for invoice debtors
        gho.addFacilitator(address(this), type(uint128).max);

        // the facilitator (not its owner) must be allowed by the pool
        depositPermissions.allow(address(facilitator));
        redeemPermissions.allow(address(facilitator));
    }

    function createGhoClaim(address creditor, address debtor, uint256 claimAmount, uint256 _dueBy) internal returns (uint256) {
        CreateClaimParams memory params = CreateClaimParams({
            creditor: creditor,
            debtor: debtor,
            claimAmount: claimAmount,
            description: "",
            token: address(gho),
            binding: ClaimBinding.Unbound,
            dueBy: _dueBy,
            impairmentGracePeriod: 60 days
        });

        return bullaClaim.createClaim(params);
    }

    function _approveGhoInvoice(uint256 invoiceId) internal {
        IBullaFactoringV2_2.ApproveInvoiceParams[] memory params = new IBullaFactoringV2_2.ApproveInvoiceParams[](1);
        params[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: invoiceId,
            targetYieldBps: interestApr,
            spreadBps: spreadBps,
            upfrontBps: upfrontBps,
            initialInvoiceValueOverride: 0
        });
        vm.prank(underwriter);
        ghoPool.approveInvoices(params);
    }

    function _fundGhoInvoice(uint256 invoiceId) internal {
        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        address[] memory receivers = new address[](1);
        receivers[0] = address(0);
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: invoiceId,
            factorerUpfrontBps: upfrontBps,
            receiverAddressIndex: 0
        });
        vm.startPrank(bob);
        bullaClaim.approve(address(ghoPool), invoiceId);
        ghoPool.fundInvoices(params, receivers);
        vm.stopPrank();
    }

    /// @dev creates, approves, and funds a GHO invoice with bob as creditor and alice as debtor
    function _setupFundedGhoInvoice(uint256 invoiceAmount) internal returns (uint256 invoiceId) {
        vm.prank(bob);
        invoiceId = createGhoClaim(bob, alice, invoiceAmount, dueBy);
        _approveGhoInvoice(invoiceId);
        _fundGhoInvoice(invoiceId);
    }

    function _payGhoInvoice(uint256 invoiceId, uint256 amount) internal {
        gho.mint(alice, amount);
        vm.startPrank(alice);
        gho.approve(address(bullaClaim), amount);
        bullaClaim.payClaim(invoiceId, amount);
        vm.stopPrank();
    }

    function testConstructorRevertsIfPoolAssetNotGho() public {
        vm.expectRevert(GhoBullaFacilitator.PoolAssetNotGho.selector);
        new GhoBullaFacilitator(IGhoToken(address(gho)), IERC4626(address(bullaFactoring)), ghoTreasury, ghoTreasuryAdmin);
    }

    function testDepositMintsGhoAndFacilitatorHoldsShares() public {
        uint256 shares = facilitator.deposit(DEPOSIT_AMOUNT);

        assertGt(shares, 0, "Deposit should issue shares");
        assertEq(ghoPool.balanceOf(address(facilitator)), shares, "Facilitator contract must hold the pool shares");
        assertEq(ghoPool.balanceOf(address(this)), 0, "Owner must not hold any shares");
        assertEq(gho.balanceOf(address(ghoPool)), DEPOSIT_AMOUNT, "Pool should hold the minted GHO");
        assertEq(gho.balanceOf(address(facilitator)), 0, "No GHO should be left in the facilitator");

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, DEPOSIT_AMOUNT, "Bucket level should equal the minted GHO");
    }

    function testDepositRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        facilitator.deposit(DEPOSIT_AMOUNT);
    }

    function testDepositRevertsAboveBucketCapacity() public {
        vm.expectRevert(MockGhoToken.FacilitatorBucketCapacityExceeded.selector);
        facilitator.deposit(uint256(BUCKET_CAPACITY) + 1);
    }

    function testRedeemRevertsForNonOwner() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        facilitator.redeem(1);
    }

    function testRedeemBurnsAllMintedGho() public {
        uint256 shares = facilitator.deposit(DEPOSIT_AMOUNT);
        uint256 assets = facilitator.redeem(shares);

        assertEq(assets, DEPOSIT_AMOUNT, "Full redemption at par should return the deposit");
        assertEq(gho.totalSupply(), 0, "All minted GHO should be burned");
        assertEq(ghoPool.balanceOf(address(facilitator)), 0, "All shares should be redeemed");

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, 0, "Bucket level should return to zero");
    }

    function testRedeemWithYieldSendsExcessToTreasury() public {
        uint256 shares = facilitator.deposit(DEPOSIT_AMOUNT);

        // generate yield: fund a GHO invoice and have the debtor pay it after 30 days
        uint256 invoiceAmount = 50_000e18;
        uint256 invoiceId = _setupFundedGhoInvoice(invoiceAmount);
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, invoiceAmount);

        uint256 assets = facilitator.redeem(shares);

        assertGt(assets, DEPOSIT_AMOUNT, "Redemption should include factoring yield");
        uint256 yieldAmount = assets - DEPOSIT_AMOUNT;
        assertGt(yieldAmount, 0, "There must be actual yield to distribute");
        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, 0, "All minted GHO should be burned against the bucket");
        assertEq(gho.balanceOf(ghoTreasury), yieldAmount, "Yield above the minted amount goes to the treasury");
        assertEq(gho.balanceOf(address(facilitator)), 0, "No GHO should be left in the facilitator");
    }

    function testQueuedRedemptionSettlesAfterPayout() public {
        uint256 shares = facilitator.deposit(DEPOSIT_AMOUNT);

        // deploy capital so the pool lacks liquidity for a full redemption
        uint256 invoiceAmount = 50_000e18;
        uint256 invoiceId = _setupFundedGhoInvoice(invoiceAmount);

        uint256 immediateAssets = facilitator.redeem(shares);

        assertLt(immediateAssets, DEPOSIT_AMOUNT, "Only part of the redemption should fill immediately");
        assertFalse(ghoPool.getRedemptionQueue().isQueueEmpty(), "Remainder should be queued");

        (, uint256 levelAfterPartial) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(levelAfterPartial, DEPOSIT_AMOUNT - immediateAssets, "Immediate proceeds should already be burned");

        // debtor pays: the pool reconciles and processes the queue, paying the facilitator
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, invoiceAmount);

        uint256 queuedPayout = gho.balanceOf(address(facilitator));
        assertGt(queuedPayout, 0, "Queued payout should have arrived at the facilitator");

        // anyone can settle once the payout lands
        vm.prank(alice);
        facilitator.settleGho();

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, 0, "All minted GHO should be burned after settlement");
        assertEq(ghoPool.balanceOf(address(facilitator)), 0, "All shares should be gone");
        assertEq(gho.balanceOf(address(facilitator)), 0, "No GHO should be left in the facilitator");
        assertGt(gho.balanceOf(ghoTreasury), 0, "Yield should have been forwarded to the treasury");
    }

    function testSettleGhoHarvestsSurplusToTreasuryWithoutMinting() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        // generate yield: fund a GHO invoice and have the debtor pay it after 30 days
        uint256 invoiceAmount = 50_000e18;
        uint256 invoiceId = _setupFundedGhoInvoice(invoiceAmount);
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, invoiceAmount);

        uint256 backing = ghoPool.previewRedeem(ghoPool.balanceOf(address(facilitator)));
        assertGt(backing, DEPOSIT_AMOUNT, "Pool position should have appreciated");

        uint256 supplyBefore = gho.totalSupply();
        (uint256 burned, uint256 yieldToTreasury) = facilitator.settleGho();

        assertEq(burned, 0, "Nothing to burn without held GHO");
        assertEq(yieldToTreasury, backing - DEPOSIT_AMOUNT, "Settle should harvest exactly the surplus");
        assertEq(gho.balanceOf(ghoTreasury), yieldToTreasury, "Harvested GHO should reach the treasury");
        assertEq(gho.totalSupply(), supplyBefore, "Harvesting must not mint any GHO");

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, DEPOSIT_AMOUNT, "Bucket level must be untouched by harvesting");
        assertApproxEqAbs(
            ghoPool.previewRedeem(ghoPool.balanceOf(address(facilitator))),
            level,
            1,
            "Remaining backing should match the bucket level"
        );

        // no double-dipping: a second settle with no new yield does nothing
        (burned, yieldToTreasury) = facilitator.settleGho();
        assertEq(burned + yieldToTreasury, 0, "Nothing should be harvested without new yield");
    }

    function testSettleGhoDoesNothingWithoutYield() public {
        facilitator.deposit(DEPOSIT_AMOUNT);
        (uint256 burned, uint256 yieldToTreasury) = facilitator.settleGho();
        assertEq(burned + yieldToTreasury, 0, "No yield to harvest at par");
        assertEq(gho.balanceOf(ghoTreasury), 0, "Treasury should receive nothing");
    }

    function testSettleGhoSkipsHarvestWhileRedemptionQueueIsNonEmpty() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        // alice invests alongside the facilitator
        uint256 aliceDeposit = 100_000e18;
        gho.mint(alice, aliceDeposit);
        vm.startPrank(alice);
        gho.approve(address(ghoPool), aliceDeposit);
        ghoPool.deposit(aliceDeposit, alice);
        vm.stopPrank();

        // realize some yield so the facilitator has a harvestable surplus
        uint256 invoiceId = _setupFundedGhoInvoice(50_000e18);
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, 50_000e18);

        // drain liquidity and queue a redemption from alice
        _setupFundedGhoInvoice(200_000e18);
        vm.startPrank(alice);
        ghoPool.redeem(ghoPool.balanceOf(alice), alice, alice);
        vm.stopPrank();
        assertFalse(ghoPool.getRedemptionQueue().isQueueEmpty(), "Alice's redemption should be queued");

        uint256 backing = ghoPool.previewRedeem(ghoPool.balanceOf(address(facilitator)));
        assertGt(backing, DEPOSIT_AMOUNT, "Facilitator should have a surplus to harvest");

        (uint256 burned, uint256 yieldToTreasury) = facilitator.settleGho();
        assertEq(burned + yieldToTreasury, 0, "Harvest must be skipped while the queue is non-empty");
        assertEq(gho.balanceOf(ghoTreasury), 0, "Treasury should receive nothing");
    }

    function testSettleGhoByNonOwnerBurnsButDoesNotHarvest() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        // generate yield: fund a GHO invoice and have the debtor pay it after 30 days
        uint256 invoiceId = _setupFundedGhoInvoice(50_000e18);
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, 50_000e18);

        // settling is open to anyone, but the harvest leg is reserved for the owner
        vm.prank(alice);
        (uint256 burned, uint256 yieldToTreasury) = facilitator.settleGho();
        assertEq(burned + yieldToTreasury, 0, "Non-owner settle must not harvest the surplus");
        assertEq(gho.balanceOf(ghoTreasury), 0, "Treasury should receive nothing from a non-owner settle");

        // the same call from the owner harvests
        (, yieldToTreasury) = facilitator.settleGho();
        assertGt(yieldToTreasury, 0, "Owner settle should harvest the surplus");
        assertEq(gho.balanceOf(ghoTreasury), yieldToTreasury, "Harvested GHO should reach the treasury");
    }

    function testSettleGhoActsAsBackingBackstop() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        // a third party re-backs the bucket by donating GHO and settling (backWithGho equivalent)
        uint256 backingContribution = 1_000e18;
        gho.mint(address(facilitator), backingContribution);
        vm.prank(alice);
        facilitator.settleGho();

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, DEPOSIT_AMOUNT - backingContribution, "Donated GHO should burn down the bucket level");
        assertEq(gho.balanceOf(ghoTreasury), 0, "Nothing should go to the treasury while under the level");
        assertEq(gho.balanceOf(address(facilitator)), 0, "No GHO should be left in the facilitator");
    }

    function testSettleGhoSweepsDonationsAboveLevelToTreasury() public {
        // a donation with no outstanding bucket level is pure excess
        gho.mint(address(facilitator), 1_000e18);
        facilitator.settleGho();

        assertEq(gho.balanceOf(ghoTreasury), 1_000e18, "Donated GHO should be swept to the treasury");
        assertEq(gho.balanceOf(address(facilitator)), 0, "No GHO should be left in the facilitator");
    }

    function testRescueTokensCannotTouchBackingTokens() public {
        vm.expectRevert(abi.encodeWithSelector(GhoBullaFacilitator.CannotRescueBackingToken.selector, address(gho)));
        facilitator.rescueTokens(address(gho), address(this), 1);

        vm.expectRevert(abi.encodeWithSelector(GhoBullaFacilitator.CannotRescueBackingToken.selector, address(ghoPool)));
        facilitator.rescueTokens(address(ghoPool), address(this), 1);

        asset.mint(address(facilitator), 100);
        facilitator.rescueTokens(address(asset), address(this), 100);
    }

    function testConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert(GhoBullaFacilitator.InvalidAddress.selector);
        new GhoBullaFacilitator(IGhoToken(address(0)), IERC4626(address(ghoPool)), ghoTreasury, ghoTreasuryAdmin);

        vm.expectRevert(GhoBullaFacilitator.InvalidAddress.selector);
        new GhoBullaFacilitator(IGhoToken(address(gho)), IERC4626(address(0)), ghoTreasury, ghoTreasuryAdmin);

        vm.expectRevert(GhoBullaFacilitator.InvalidAddress.selector);
        new GhoBullaFacilitator(IGhoToken(address(gho)), IERC4626(address(ghoPool)), address(0), ghoTreasuryAdmin);

        vm.expectRevert(GhoBullaFacilitator.InvalidAddress.selector);
        new GhoBullaFacilitator(IGhoToken(address(gho)), IERC4626(address(ghoPool)), ghoTreasury, address(0));
    }

    function testUpdateGhoTreasuryOnlyByTreasuryAdmin() public {
        address newTreasury = address(0xbeef);

        // the owner (this test contract) must NOT be able to redirect yield
        vm.expectRevert(abi.encodeWithSelector(GhoBullaFacilitator.CallerNotTreasuryAdmin.selector, address(this)));
        facilitator.updateGhoTreasury(newTreasury);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GhoBullaFacilitator.CallerNotTreasuryAdmin.selector, alice));
        facilitator.updateGhoTreasury(newTreasury);

        vm.prank(ghoTreasuryAdmin);
        vm.expectEmit();
        emit GhoTreasuryUpdated(ghoTreasury, newTreasury);
        facilitator.updateGhoTreasury(newTreasury);
        assertEq(facilitator.ghoTreasury(), newTreasury);
    }

    function testUpdateGhoTreasuryRevertsOnZeroAddress() public {
        vm.prank(ghoTreasuryAdmin);
        vm.expectRevert(GhoBullaFacilitator.InvalidAddress.selector);
        facilitator.updateGhoTreasury(address(0));
    }

    function testRescueTokensRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        facilitator.rescueTokens(address(asset), alice, 1);
    }

    function testDepositAndRedeemRevertIfFacilitatorNotAllowedByPool() public {
        depositPermissions.disallow(address(facilitator));
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedDeposit(address)", address(facilitator)));
        facilitator.deposit(DEPOSIT_AMOUNT);

        depositPermissions.allow(address(facilitator));
        uint256 shares = facilitator.deposit(DEPOSIT_AMOUNT);

        redeemPermissions.disallow(address(facilitator));
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedRedeem(address)", address(facilitator)));
        facilitator.redeem(shares);
    }

    function testDepositAndRedeemEmitEvents() public {
        uint256 expectedShares = ghoPool.previewDeposit(DEPOSIT_AMOUNT);

        vm.expectEmit();
        emit Deposited(DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, expectedShares);
        facilitator.deposit(DEPOSIT_AMOUNT);

        vm.expectEmit();
        emit Redeemed(expectedShares, DEPOSIT_AMOUNT);
        vm.expectEmit();
        emit GhoSettled(DEPOSIT_AMOUNT, 0);
        facilitator.redeem(expectedShares);
    }

    function testPartialRedeemWithYieldStaysFullyBackedAndHarvests() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        uint256 invoiceId = _setupFundedGhoInvoice(50_000e18);
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, 50_000e18);

        uint256 shares = ghoPool.balanceOf(address(facilitator));
        uint256 backing = ghoPool.previewRedeem(shares);
        uint256 surplus = backing - DEPOSIT_AMOUNT;
        assertGt(surplus, 0, "Pool position should have appreciated");

        uint256 assets = facilitator.redeem(shares / 2);

        // the proceeds are burned in full (still below the level), and since the owner
        // triggered the settle, the surplus embedded in the remaining shares is harvested too
        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, DEPOSIT_AMOUNT - assets, "Redemption proceeds should be burned in full");
        assertApproxEqAbs(gho.balanceOf(ghoTreasury), surplus, 2, "Owner redemption should also harvest the surplus");
        assertApproxEqAbs(
            ghoPool.previewRedeem(ghoPool.balanceOf(address(facilitator))),
            level,
            2,
            "Remaining position should stay exactly 1:1 backed"
        );
    }

    function testDepositRecyclesHeldGhoBeforeMinting() public {
        uint256 shares = facilitator.deposit(DEPOSIT_AMOUNT);

        // deploy capital, then redeem everything so the unfilled remainder gets queued
        uint256 invoiceId = _setupFundedGhoInvoice(50_000e18);
        uint256 immediateAssets = facilitator.redeem(shares);
        assertLt(immediateAssets, DEPOSIT_AMOUNT, "Remainder should have been queued");

        // debtor pays: the queue processes and the payout lands as a GHO balance
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, 50_000e18);

        uint256 held = gho.balanceOf(address(facilitator));
        assertGt(held, 0, "Queued payout should be sitting in the facilitator");
        (, uint256 levelBefore) = gho.getFacilitatorBucket(address(facilitator));
        uint256 supplyBefore = gho.totalSupply();
        uint256 poolBalanceBefore = gho.balanceOf(address(ghoPool));

        // redeposit: the held GHO is recycled and only the shortfall is minted
        facilitator.deposit(DEPOSIT_AMOUNT);

        (, uint256 levelAfter) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(levelAfter, levelBefore + DEPOSIT_AMOUNT - held, "Only the shortfall should be minted");
        assertEq(gho.totalSupply(), supplyBefore + DEPOSIT_AMOUNT - held, "Supply should grow only by the minted part");
        assertEq(gho.balanceOf(address(facilitator)), 0, "Held GHO should be fully redeployed");
        assertEq(gho.balanceOf(address(ghoPool)), poolBalanceBefore + DEPOSIT_AMOUNT, "Pool should receive the full deposit");
    }

    function testDepositLargerHeldBalanceMintsNothing() public {
        // held GHO above the deposit size: nothing is minted, remainder stays for settlement
        gho.mint(address(facilitator), 5_000e18);

        facilitator.deposit(1_000e18);

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, 0, "Nothing should have been minted against the bucket");
        assertEq(gho.balanceOf(address(facilitator)), 4_000e18, "Unused balance should remain for settleGho");
        assertEq(gho.balanceOf(address(ghoPool)), 1_000e18, "Pool should hold the deposit");
    }

    function testSettleGhoHarvestCappedByPoolLiquidity() public {
        facilitator.deposit(DEPOSIT_AMOUNT);

        // crank up the yield so the surplus comfortably exceeds the funding fees below
        interestApr = 5000;
        uint256 invoiceId = _setupFundedGhoInvoice(50_000e18);
        vm.warp(block.timestamp + 30 days);
        _payGhoInvoice(invoiceId, 50_000e18);

        uint256 backing = ghoPool.previewRedeem(ghoPool.balanceOf(address(facilitator)));
        uint256 surplus = backing - DEPOSIT_AMOUNT;

        // deploy most of the pool's liquidity into a second invoice, leaving less cash
        // than the harvestable surplus
        uint256 face = (ghoPool.totalAssets() - surplus / 2) * 10000 / upfrontBps;
        _setupFundedGhoInvoice(face);

        uint256 withdrawable = ghoPool.maxWithdraw(address(facilitator));
        assertGt(withdrawable, 0, "Some liquidity should remain");
        assertLt(withdrawable, surplus, "Setup must leave less liquidity than the surplus");

        (, uint256 yieldToTreasury) = facilitator.settleGho();

        assertEq(yieldToTreasury, withdrawable, "Harvest should be capped at the pool's available liquidity");
        assertEq(gho.balanceOf(ghoTreasury), withdrawable, "Treasury should receive the capped harvest");

        (, uint256 level) = gho.getFacilitatorBucket(address(facilitator));
        assertEq(level, DEPOSIT_AMOUNT, "Bucket level must be untouched");
        assertApproxEqAbs(
            ghoPool.previewRedeem(ghoPool.balanceOf(address(facilitator))),
            DEPOSIT_AMOUNT + surplus - withdrawable,
            1,
            "Unharvested surplus should remain in the pool as extra backing"
        );
    }
}
