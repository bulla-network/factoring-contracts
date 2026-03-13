// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { BullaFactoringV2_2 } from 'contracts/BullaFactoring.sol';
import { PermissionsWithAragon } from 'contracts/PermissionsWithAragon.sol';
import { PermissionsWithSafe } from 'contracts/PermissionsWithSafe.sol';
import { BullaClaimV2InvoiceProviderAdapterV2 } from 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol';
import { MockUSDC } from 'contracts/mocks/MockUSDC.sol';
import { MockPermissions } from 'contracts/mocks/MockPermissions.sol';
import { DAOMock } from 'contracts/mocks/DAOMock.sol';
import { TestSafe } from 'contracts/mocks/gnosisSafe.sol';

import "../../contracts/interfaces/IInvoiceProviderAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "contracts/interfaces/IBullaFactoring.sol";
import {IBullaClaimV2, LockState} from "bulla-contracts-v2/src/interfaces/IBullaClaimV2.sol";
import {IBullaFrendLendV2} from "bulla-contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {BullaFrendLendV2} from "bulla-contracts-v2/src/BullaFrendLendV2.sol";
import {BullaControllerRegistry} from "bulla-contracts-v2/src/BullaControllerRegistry.sol";
import {BullaClaimV2} from "bulla-contracts-v2/src/BullaClaimV2.sol";
import {IBullaInvoice} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";
import {BullaInvoice} from "bulla-contracts-v2/src/BullaInvoice.sol";
import {BullaApprovalRegistry} from "bulla-contracts-v2/src/BullaApprovalRegistry.sol";
import {CreateClaimParams, ClaimBinding} from "bulla-contracts-v2/src/types/Types.sol";
import {CreateInvoiceParams, InterestConfig} from "bulla-contracts-v2/src/interfaces/IBullaInvoice.sol";

contract CommonSetup is Test {
    BullaFactoringV2_2 public bullaFactoring;
    BullaClaimV2InvoiceProviderAdapterV2 public invoiceAdapterBulla;
    MockUSDC public asset;
    MockPermissions public depositPermissions;
    MockPermissions public redeemPermissions;
    MockPermissions public factoringPermissions;
    PermissionsWithAragon public permissionsWithAragon;
    DAOMock public daoMock;
    PermissionsWithSafe public permissionsWithSafe;
    TestSafe public testSafe;
    BullaControllerRegistry public bullaControllerRegistry;
    BullaApprovalRegistry public bullaApprovalRegistry;
    MockPermissions public feeExemptionWhitelist;
    IBullaFrendLendV2 public bullaFrendLend;
    IBullaClaimV2 public bullaClaim;
    IBullaInvoice public bullaInvoice;

    uint256 bobPK = 0x1;
    uint256 charliePK = 0x2;

    address alice = address(0xA11c3);
    address bob = vm.addr(bobPK);
    address underwriter = address(0x1222);
    address userWithoutPermissions = address(0x743123);
    address charlie = vm.addr(charliePK);

    uint16 interestApr = 730;
    uint16 spreadBps = 1000;
    uint16 upfrontBps = 8000;
    uint256 dueBy = block.timestamp + 30 days;

    address bullaDao = address(this);
    uint16 protocolFeeBps = 25;
    uint16 adminFeeBps = 25;
    uint16 targetYield = 730;

    string poolName = 'Test Pool';
    string poolTokenName = 'Test Bulla Factoring Pool Token';
    string poolTokenSymbol = 'BFT-Test';

    function setUp() public virtual {
        asset = new MockUSDC();
        depositPermissions = new MockPermissions();
        factoringPermissions = new MockPermissions();
        redeemPermissions = new MockPermissions();
        daoMock = new DAOMock();
        feeExemptionWhitelist = new MockPermissions();
        bullaControllerRegistry = new BullaControllerRegistry();
        bullaApprovalRegistry = new BullaApprovalRegistry(address(bullaControllerRegistry));
        bullaClaim = new BullaClaimV2(address(bullaApprovalRegistry), LockState.Unlocked, 0, address(feeExemptionWhitelist));
        bullaFrendLend = new BullaFrendLendV2(address(bullaClaim), address(this), 50, 0);
        bullaInvoice = new BullaInvoice(address(bullaClaim), address(this), 50);
        invoiceAdapterBulla = new BullaClaimV2InvoiceProviderAdapterV2(address(bullaClaim), address(bullaFrendLend), address(bullaInvoice));
        bullaApprovalRegistry.setAuthorizedContract(address(bullaClaim), true);
        
        address[] memory safeOwners = new address[](2);
        safeOwners[0] = alice;
        safeOwners[1] = address(this);
        testSafe = new TestSafe(safeOwners, uint8(2));
        bytes32 ALLOW_PERMISSION_ID = keccak256("ALLOW_PERMISSION");
        permissionsWithAragon = new PermissionsWithAragon(address(daoMock), ALLOW_PERMISSION_ID);
        permissionsWithSafe = new PermissionsWithSafe(address(testSafe));

        // Allow alice and bob for deposits, and bob for factoring
        depositPermissions.allow(alice);
        depositPermissions.allow(bob);
        redeemPermissions.allow(alice);
        redeemPermissions.allow(bob);
        factoringPermissions.allow(bob);
        factoringPermissions.allow(address(this));

        bullaFactoring = new BullaFactoringV2_2(asset, invoiceAdapterBulla, bullaFrendLend, underwriter, depositPermissions, redeemPermissions, factoringPermissions, bullaDao ,protocolFeeBps, adminFeeBps, poolName, targetYield, poolTokenName, poolTokenSymbol, address(0x1999), uint16(100), uint16(500), uint16(5000));

        bullaFrendLend.addToCallbackWhitelist(address(bullaFactoring), bullaFactoring.onLoanOfferAccepted.selector);
        bullaClaim.addToPaidCallbackWhitelist(address(bullaFactoring), bullaFactoring.reconcileSingleInvoice.selector);

        asset.mint(address(this), 10000 ether);
        asset.mint(alice, 1000 ether);
        asset.mint(bob, 1000 ether);
        asset.mint(charlie, 1000 ether);

        vm.startPrank(alice);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();

        vm.startPrank(charlie);
        asset.approve(address(bullaFactoring), 1000 ether);
        vm.stopPrank();
    }

    function permitUser(address user, bool canFactor, uint256 fundingAmount) internal {
        depositPermissions.allow(user);
        redeemPermissions.allow(user);
        if (canFactor) {
            factoringPermissions.allow(user);
        }
        if (fundingAmount > 0) {
            asset.mint(user, fundingAmount);
            vm.startPrank(user);
            asset.approve(address(bullaFactoring), fundingAmount);
            vm.stopPrank();
        }
    }

    function createClaim(
        address creditor, 
        address debtor, 
        uint256 claimAmount, 
        uint256 _dueBy
    ) internal returns (uint256) {
        string memory description = "";
        address claimToken = address(asset);

        CreateClaimParams memory params = CreateClaimParams({
            creditor: creditor,
            debtor: debtor,
            claimAmount: claimAmount,
            description: description,
            token: claimToken,
            binding: ClaimBinding.Unbound,
            dueBy: _dueBy,
            impairmentGracePeriod: 60 days
        });

        return bullaClaim.createClaim(params);
    }

    function createInvoice(
        address creditor, 
        address debtor, 
        uint256 principalAmount,
        uint256 _dueBy,
        uint256 interestRateBps,
        uint256 numberOfPeriodsPerYear
    ) internal returns (uint256) {
        CreateInvoiceParams memory params = CreateInvoiceParams({
            creditor: creditor,
            debtor: debtor,
            claimAmount: principalAmount,
            description: "Test Invoice",
            token: address(asset),
            dueBy: _dueBy,
            deliveryDate: 0, // No delivery date for simple invoices
            binding: ClaimBinding.Unbound,
            lateFeeConfig: InterestConfig({
                interestRateBps: uint16(interestRateBps),
                numberOfPeriodsPerYear: uint16(numberOfPeriodsPerYear)
            }),
            impairmentGracePeriod: 60 days,
            depositAmount: 0 // No deposit for simple invoices
        });

        return bullaInvoice.createInvoice(params);
    }

    /// @dev Helper function to extract queued shares and assets from RedemptionQueued events
    /// @return queuedShares Amount of shares queued (0 if none)
    /// @return queuedAssets Amount of assets queued (0 if none)
    function getQueuedSharesAndAssetsFromEvent() internal returns (uint256 queuedShares, uint256 queuedAssets) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("RedemptionQueued(address,address,uint256,uint256,uint256)")) {
                (uint256 shares, uint256 assets, ) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                return (shares, assets);
            }
        }
        return (0, 0);
    }

    // ============ Convenience helpers for single-invoice approve/fund ============

    /// @dev Wraps a single approveInvoice call into the batch approveInvoices interface
    function _approveInvoice(
        uint256 invoiceId,
        uint16 _targetYieldBps,
        uint16 _spreadBps,
        uint16 _upfrontBps,
        uint256 _initialInvoiceValueOverride
    ) internal {
        IBullaFactoringV2_2.ApproveInvoiceParams[] memory params = new IBullaFactoringV2_2.ApproveInvoiceParams[](1);
        params[0] = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: invoiceId,
            targetYieldBps: _targetYieldBps,
            spreadBps: _spreadBps,
            upfrontBps: _upfrontBps,
            initialInvoiceValueOverride: _initialInvoiceValueOverride
        });
        bullaFactoring.approveInvoices(params);
    }

    /// @dev Wraps a single fundInvoice call into the batch fundInvoices interface
    function _fundInvoice(
        uint256 invoiceId,
        uint16 factorerUpfrontBps,
        address receiverAddress
    ) internal returns (uint256) {
        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        address[] memory receivers = new address[](1);
        receivers[0] = receiverAddress;
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: invoiceId,
            factorerUpfrontBps: factorerUpfrontBps,
            receiverAddressIndex: 0
        });
        uint256[] memory amounts = bullaFactoring.fundInvoices(params, receivers);
        return amounts[0];
    }

    /// @dev Wraps a single fundInvoice call for use with vm.expectRevert (no return value access)
    function _fundInvoiceExpectRevert(
        uint256 invoiceId,
        uint16 factorerUpfrontBps,
        address receiverAddress
    ) internal {
        IBullaFactoringV2_2.FundInvoiceParams[] memory params = new IBullaFactoringV2_2.FundInvoiceParams[](1);
        address[] memory receivers = new address[](1);
        receivers[0] = receiverAddress;
        params[0] = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: invoiceId,
            factorerUpfrontBps: factorerUpfrontBps,
            receiverAddressIndex: 0
        });
        bullaFactoring.fundInvoices(params, receivers);
    }
}

// ============ Builder Patterns ============

library ApproveInvoiceParamsBuilder {
    function create() internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        return IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: 0,
            targetYieldBps: 0,
            spreadBps: 0,
            upfrontBps: 0,
            initialInvoiceValueOverride: 0
        });
    }

    function withInvoiceId(IBullaFactoringV2_2.ApproveInvoiceParams memory self, uint256 invoiceId) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        self.invoiceId = invoiceId;
        return self;
    }

    function withTargetYieldBps(IBullaFactoringV2_2.ApproveInvoiceParams memory self, uint16 targetYieldBps) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        self.targetYieldBps = targetYieldBps;
        return self;
    }

    function withSpreadBps(IBullaFactoringV2_2.ApproveInvoiceParams memory self, uint16 spreadBps) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        self.spreadBps = spreadBps;
        return self;
    }

    function withUpfrontBps(IBullaFactoringV2_2.ApproveInvoiceParams memory self, uint16 upfrontBps) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        self.upfrontBps = upfrontBps;
        return self;
    }

    function withInitialInvoiceValueOverride(IBullaFactoringV2_2.ApproveInvoiceParams memory self, uint256 initialInvoiceValueOverride) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        self.initialInvoiceValueOverride = initialInvoiceValueOverride;
        return self;
    }

    function build(IBullaFactoringV2_2.ApproveInvoiceParams memory self) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        return self;
    }
}

library FundInvoiceParamsBuilder {
    function create() internal pure returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        return IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: 0,
            factorerUpfrontBps: 0,
            receiverAddressIndex: 0
        });
    }

    function withInvoiceId(IBullaFactoringV2_2.FundInvoiceParams memory self, uint256 invoiceId) internal pure returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        self.invoiceId = invoiceId;
        return self;
    }

    function withFactorerUpfrontBps(IBullaFactoringV2_2.FundInvoiceParams memory self, uint16 factorerUpfrontBps) internal pure returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        self.factorerUpfrontBps = factorerUpfrontBps;
        return self;
    }

    function withReceiverAddressIndex(IBullaFactoringV2_2.FundInvoiceParams memory self, uint8 receiverAddressIndex) internal pure returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        self.receiverAddressIndex = receiverAddressIndex;
        return self;
    }

    function build(IBullaFactoringV2_2.FundInvoiceParams memory self) internal pure returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        return self;
    }
}
