// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BullaFactoringV2_2} from "contracts/BullaFactoring.sol";
import {IBullaFactoringV2_2} from "contracts/interfaces/IBullaFactoring.sol";
import {Permissions} from "contracts/Permissions.sol";
import {IBullaClaimV2} from "bulla-contracts-v2/src/interfaces/IBullaClaimV2.sol";
import {IBullaApprovalRegistry} from "bulla-contracts-v2/src/interfaces/IBullaApprovalRegistry.sol";
import {IBullaFrendLendV2, LoanRequestParams} from "bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {IBullaInvoice, CreateInvoiceParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {CreateClaimParams, ClaimBinding, CreateClaimApprovalType} from "bulla-contracts-v2/src/types/Types.sol";
import {DeployBullaFactoring} from "../../../../script/DeployBullaFactoring.s.sol";
import {DeployConfig} from "../../../../script/DeployConfig.sol";

/// @title Pre-deployment fork smoke test (POOLDEPLOY-11 to POOLDEPLOY-14)
/// @notice Spec: bulla-specs deploy-pool.md (POOLDEPLOY). Forks the target chain, deploys the pool with the
///         real DeployBullaFactoring script and the real deploy config, whitelists the paid callback as the
///         Bulla Claim owner (12), then for every controller the chain has runs pay (11), unfactor (13) and
///         impair (14).
/// @dev Driven by scripts/predeploy-checks.ts, which sets the deploy env vars and PREDEPLOY_FORK=true.
///      Without PREDEPLOY_FORK every test is skipped, so `make test_fork` stays unaffected.
contract TestPreDeployFork is Test {
    uint256 internal constant DEPLOYER_PK = 0xA11CE5EED;
    uint256 internal constant GRACE_PERIOD = 60 days;
    uint256 internal constant TERM = 30 days;
    uint16 internal constant UPFRONT_BPS = 8000;

    DeployConfig.NetworkConfig internal cfg;
    BullaFactoringV2_2 internal pool;
    IERC20 internal asset;
    IBullaClaimV2 internal bullaClaim;
    uint256 internal unit;

    address internal investor = makeAddr("pooldeploy-investor");
    address internal creditor = makeAddr("pooldeploy-creditor");
    address internal debtor = makeAddr("pooldeploy-debtor");

    enum Controller {
        BullaClaim,
        BullaInvoice,
        FrendLend
    }

    modifier onlyPreDeployFork() {
        if (!vm.envOr("PREDEPLOY_FORK", false)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// Skips a test for a controller the chain doesn't have
    modifier onlyIfController(Controller c) {
        address controller = c == Controller.BullaInvoice ? cfg.bullaInvoiceAddress : cfg.bullaFrendLendAddress;
        if (controller == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (!vm.envOr("PREDEPLOY_FORK", false)) return;

        // Deploy exactly as the real deploy would, from the same env config.
        // POOLDEPLOY-10 has already ensured BULLA_FACTORING_ADDRESS is empty, so this deploys a fresh pool.
        vm.setEnv("DEPLOY_PK", vm.toString(bytes32(DEPLOYER_PK)));
        DeployBullaFactoring deployScript = new DeployBullaFactoring();
        deployScript.run();
        cfg = deployScript.getConfig();

        pool = BullaFactoringV2_2(cfg.bullaFactoringAddress);
        asset = IERC20(cfg.underlyingAsset);
        bullaClaim = IBullaClaimV2(cfg.bullaClaim);
        unit = 10 ** IERC20Metadata(cfg.underlyingAsset).decimals();

        // Permissions are not under test here: allow the test accounts on whatever contracts are configured
        _allow(address(pool.depositPermissions()), investor);
        _allow(address(pool.redeemPermissions()), investor);
        _allow(address(pool.factoringPermissions()), creditor);

        // Controllers create claims on the user's behalf through the approval registry
        _approveController(cfg.bullaInvoiceAddress);
        _approveController(cfg.bullaFrendLendAddress);

        // POOLDEPLOY-12: act as the Bulla Claim owner and whitelist the paid callback the way
        // script/WhitelistCallback.s.sol does. On the real chain the owner does this after the deploy.
        vm.prank(bullaClaim.owner());
        bullaClaim.addToPaidCallbackWhitelist(address(pool), pool.reconcileSingleInvoice.selector);

        // Liquidity
        deal(address(asset), investor, 100_000 * unit, true);
        vm.startPrank(investor);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(100_000 * unit, investor);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-12
    // ------------------------------------------------------------------

    function test_POOLDEPLOY12_paidCallbackWhitelisted() public onlyPreDeployFork {
        assertTrue(
            bullaClaim.isPaidCallbackWhitelisted(address(pool), pool.reconcileSingleInvoice.selector),
            "POOLDEPLOY-12: reconcileSingleInvoice not whitelisted on BullaClaimV2"
        );
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-11, POOLDEPLOY-13, POOLDEPLOY-14: once per controller the chain has
    // ------------------------------------------------------------------

    function test_POOLDEPLOY11_bullaClaim_paidIsReconciled() public onlyPreDeployFork {
        _paidIsReconciled(Controller.BullaClaim);
    }

    function test_POOLDEPLOY11_bullaInvoice_paidIsReconciled() public onlyPreDeployFork onlyIfController(Controller.BullaInvoice) {
        _paidIsReconciled(Controller.BullaInvoice);
    }

    function test_POOLDEPLOY11_frendLend_paidIsReconciled() public onlyPreDeployFork onlyIfController(Controller.FrendLend) {
        _paidIsReconciled(Controller.FrendLend);
    }

    function test_POOLDEPLOY13_bullaClaim_unfactorReturnsToCreditor() public onlyPreDeployFork {
        _unfactorReturnsToCreditor(Controller.BullaClaim);
    }

    function test_POOLDEPLOY13_bullaInvoice_unfactorReturnsToCreditor()
        public
        onlyPreDeployFork
        onlyIfController(Controller.BullaInvoice)
    {
        _unfactorReturnsToCreditor(Controller.BullaInvoice);
    }

    function test_POOLDEPLOY13_frendLend_unfactorReturnsToCreditor()
        public
        onlyPreDeployFork
        onlyIfController(Controller.FrendLend)
    {
        _unfactorReturnsToCreditor(Controller.FrendLend);
    }

    function test_POOLDEPLOY14_bullaClaim_overdueIsImpaired() public onlyPreDeployFork {
        _overdueIsImpaired(Controller.BullaClaim);
    }

    function test_POOLDEPLOY14_bullaInvoice_overdueIsImpaired() public onlyPreDeployFork onlyIfController(Controller.BullaInvoice) {
        _overdueIsImpaired(Controller.BullaInvoice);
    }

    function test_POOLDEPLOY14_frendLend_overdueIsImpaired() public onlyPreDeployFork onlyIfController(Controller.FrendLend) {
        _overdueIsImpaired(Controller.FrendLend);
    }

    /// POOLDEPLOY-11: fund -> pay -> reconciled through the paid callback
    function _paidIsReconciled(Controller c) internal {
        uint256 id = _create(c, 1_000 * unit);
        _approveAndFund(c, id);
        assertTrue(_isActive(id), "POOLDEPLOY-11: funded invoice not active");
        _pay(c, id);
        assertFalse(_isActive(id), "POOLDEPLOY-11: paid invoice not reconciled (paid callback)");
    }

    /// POOLDEPLOY-13: fund -> unfactor -> back to the creditor
    function _unfactorReturnsToCreditor(Controller c) internal {
        uint256 amount = 1_000 * unit;
        uint256 id = _create(c, amount);
        _approveAndFund(c, id);
        deal(address(asset), creditor, amount, true);
        vm.startPrank(creditor);
        asset.approve(address(pool), type(uint256).max);
        pool.unfactorInvoice(id);
        vm.stopPrank();
        assertFalse(_isActive(id), "POOLDEPLOY-13: unfactored invoice still active");
        assertEq(bullaClaim.ownerOf(id), creditor, "POOLDEPLOY-13: claim not returned to creditor");
    }

    /// POOLDEPLOY-14: fund -> overdue past grace -> impaired by the insurer (goes through adapter.getImpairTarget)
    function _overdueIsImpaired(Controller c) internal {
        uint256 amount = 1_000 * unit;
        uint256 id = _create(c, amount);
        _approveAndFund(c, id);
        vm.warp(block.timestamp + TERM + GRACE_PERIOD + 1 days);

        address insurer = pool.insurer();
        deal(address(asset), insurer, amount, true);
        vm.startPrank(insurer);
        asset.approve(address(pool), type(uint256).max);
        pool.impairInvoice(id);
        vm.stopPrank();

        (bool isImpaired,,,) = pool.impairmentInfo(id);
        assertTrue(isImpaired, "POOLDEPLOY-14: impairInvoice did not impair");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _create(Controller c, uint256 amount) internal returns (uint256 claimId) {
        uint256 fee = _protocolFee();
        uint256 dueBy = block.timestamp + TERM;

        if (c == Controller.BullaClaim) {
            vm.deal(creditor, fee);
            vm.prank(creditor);
            claimId = bullaClaim.createClaim{value: fee}(
                CreateClaimParams({
                    creditor: creditor,
                    debtor: debtor,
                    claimAmount: amount,
                    description: "POOLDEPLOY-11",
                    token: address(asset),
                    binding: ClaimBinding.Unbound,
                    dueBy: dueBy,
                    impairmentGracePeriod: GRACE_PERIOD
                })
            );
        } else if (c == Controller.BullaInvoice) {
            vm.deal(creditor, fee);
            vm.prank(creditor);
            claimId = IBullaInvoice(cfg.bullaInvoiceAddress).createInvoice{value: fee}(
                CreateInvoiceParams({
                    creditor: creditor,
                    debtor: debtor,
                    claimAmount: amount,
                    description: "POOLDEPLOY-11",
                    token: address(asset),
                    dueBy: dueBy,
                    deliveryDate: 0,
                    binding: ClaimBinding.Unbound,
                    lateFeeConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
                    impairmentGracePeriod: GRACE_PERIOD,
                    depositAmount: 0
                })
            );
        } else {
            IBullaFrendLendV2 frendLend = IBullaFrendLendV2(cfg.bullaFrendLendAddress);
            deal(address(asset), creditor, amount, true);
            vm.startPrank(creditor);
            asset.approve(address(frendLend), amount);
            uint256 offerId = frendLend.offerLoan(
                LoanRequestParams({
                    termLength: TERM,
                    interestConfig: InterestConfig({interestRateBps: 0, numberOfPeriodsPerYear: 0}),
                    loanAmount: amount,
                    creditor: creditor,
                    debtor: debtor,
                    description: "POOLDEPLOY-11",
                    token: address(asset),
                    impairmentGracePeriod: GRACE_PERIOD,
                    expiresAt: 0,
                    callbackContract: address(0),
                    callbackSelector: bytes4(0)
                })
            );
            vm.stopPrank();

            vm.deal(debtor, fee);
            vm.prank(debtor);
            claimId = frendLend.acceptLoan{value: fee}(offerId);
        }
    }

    function _approveAndFund(Controller c, uint256 claimId) internal {
        IBullaFactoringV2_2.ApproveInvoiceParams[] memory approvals = new IBullaFactoringV2_2.ApproveInvoiceParams[](1);
        approvals[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: claimId,
            targetYieldBps: uint16(cfg.targetYieldBps),
            spreadBps: 0,
            upfrontBps: UPFRONT_BPS,
            initialInvoiceValueOverride: 0
        });
        vm.prank(cfg.underwriter);
        pool.approveInvoices(approvals);

        IBullaFactoringV2_2.FundInvoiceParams[] memory funds = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        funds[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: claimId,
            factorerUpfrontBps: UPFRONT_BPS,
            receiverAddressIndex: 0
        });
        address[] memory receivers = new address[](1);

        // Controlled claims are approved through their controller
        address nft = c == Controller.BullaClaim
            ? address(bullaClaim)
            : c == Controller.BullaInvoice ? cfg.bullaInvoiceAddress : cfg.bullaFrendLendAddress;
        vm.startPrank(creditor);
        IERC721(nft).approve(address(pool), claimId);
        pool.fundInvoices(funds, receivers);
        vm.stopPrank();
    }

    function _pay(Controller c, uint256 claimId) internal {
        if (c == Controller.FrendLend) {
            IBullaFrendLendV2 frendLend = IBullaFrendLendV2(cfg.bullaFrendLendAddress);
            (uint256 principal, uint256 interest) = frendLend.getTotalAmountDue(claimId);
            uint256 due = principal + interest;
            deal(address(asset), debtor, due, true);
            vm.startPrank(debtor);
            asset.approve(address(frendLend), due);
            frendLend.payLoan(claimId, due);
            vm.stopPrank();
            return;
        }

        uint256 owed = bullaClaim.getClaim(claimId).claimAmount;
        deal(address(asset), debtor, owed, true);
        vm.startPrank(debtor);
        if (c == Controller.BullaClaim) {
            asset.approve(address(bullaClaim), owed);
            bullaClaim.payClaim(claimId, owed);
        } else {
            asset.approve(cfg.bullaInvoiceAddress, owed);
            IBullaInvoice(cfg.bullaInvoiceAddress).payInvoice(claimId, owed);
        }
        vm.stopPrank();
    }

    function _protocolFee() internal view returns (uint256) {
        bool exempt =
            bullaClaim.feeExemptions().isAllowed(creditor) || bullaClaim.feeExemptions().isAllowed(debtor);
        return exempt ? 0 : bullaClaim.CORE_PROTOCOL_FEE();
    }

    function _isActive(uint256 claimId) internal view returns (bool) {
        uint256[] memory active = pool.getActiveInvoices();
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == claimId) return true;
        }
        return false;
    }

    function _approveController(address controller) internal {
        if (controller == address(0)) return;
        IBullaApprovalRegistry registry = bullaClaim.approvalRegistry(); // fetch first: prank applies to the next call
        address[2] memory accounts = [creditor, debtor];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(accounts[i]);
            // FrendLend loans are bound to the debtor, so binding must be allowed
            registry.approveCreateClaim(controller, CreateClaimApprovalType.Approved, type(uint64).max, true);
        }
    }

    function _allow(address permissions, address account) internal {
        vm.mockCall(permissions, abi.encodeWithSelector(Permissions.isAllowed.selector, account), abi.encode(true));
    }
}
