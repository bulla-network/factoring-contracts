// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "contracts/interfaces/IBullaFactoring.sol";

// ============ Builder Patterns ============

struct ApproveInvoiceBuilder {
    uint256 invoiceId;
    uint16 targetYieldBps;
    uint16 spreadBps;
    uint16 upfrontBps;
    uint256 initialInvoiceValueOverride;
}

library ApproveInvoiceParamsBuilder {
    function create() internal pure returns (ApproveInvoiceBuilder memory) {
        return ApproveInvoiceBuilder(0, 0, 0, 0, 0);
    }

    function withInvoiceId(ApproveInvoiceBuilder memory self, uint256 invoiceId) internal pure returns (ApproveInvoiceBuilder memory) {
        self.invoiceId = invoiceId;
        return self;
    }

    function withTargetYieldBps(ApproveInvoiceBuilder memory self, uint16 targetYieldBps) internal pure returns (ApproveInvoiceBuilder memory) {
        self.targetYieldBps = targetYieldBps;
        return self;
    }

    function withSpreadBps(ApproveInvoiceBuilder memory self, uint16 spreadBps) internal pure returns (ApproveInvoiceBuilder memory) {
        self.spreadBps = spreadBps;
        return self;
    }

    function withUpfrontBps(ApproveInvoiceBuilder memory self, uint16 upfrontBps) internal pure returns (ApproveInvoiceBuilder memory) {
        self.upfrontBps = upfrontBps;
        return self;
    }

    function withInitialInvoiceValueOverride(ApproveInvoiceBuilder memory self, uint256 initialInvoiceValueOverride) internal pure returns (ApproveInvoiceBuilder memory) {
        self.initialInvoiceValueOverride = initialInvoiceValueOverride;
        return self;
    }

    function build(ApproveInvoiceBuilder memory self) internal pure returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        return IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: self.invoiceId,
            targetYieldBps: self.targetYieldBps,
            spreadBps: self.spreadBps,
            upfrontBps: self.upfrontBps,
            initialInvoiceValueOverride: self.initialInvoiceValueOverride
        });
    }
}

struct FundInvoiceBuilder {
    uint256 invoiceId;
    uint16 factorerUpfrontBps;
    uint8 receiverAddressIndex;
}

library FundInvoiceParamsBuilder {
    function create() internal pure returns (FundInvoiceBuilder memory) {
        return FundInvoiceBuilder(0, 0, 0);
    }

    function withInvoiceId(FundInvoiceBuilder memory self, uint256 invoiceId) internal pure returns (FundInvoiceBuilder memory) {
        self.invoiceId = invoiceId;
        return self;
    }

    function withFactorerUpfrontBps(FundInvoiceBuilder memory self, uint16 factorerUpfrontBps) internal pure returns (FundInvoiceBuilder memory) {
        self.factorerUpfrontBps = factorerUpfrontBps;
        return self;
    }

    function withReceiverAddressIndex(FundInvoiceBuilder memory self, uint8 receiverAddressIndex) internal pure returns (FundInvoiceBuilder memory) {
        self.receiverAddressIndex = receiverAddressIndex;
        return self;
    }

    function build(FundInvoiceBuilder memory self) internal pure returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        return IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: self.invoiceId,
            factorerUpfrontBps: self.factorerUpfrontBps,
            receiverAddressIndex: self.receiverAddressIndex
        });
    }
}

// ============ Convenience Helpers ============

/// @dev Base contract providing single-invoice convenience wrappers around batch interfaces
abstract contract BatchTestHelpers {
    /// @dev Override to return the factoring contract instance
    function _factoringContract() internal view virtual returns (IBullaFactoringV2_2);

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
        _factoringContract().approveInvoices(params);
    }

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
        uint256[] memory amounts = _factoringContract().fundInvoices(params, receivers);
        return amounts[0];
    }

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
        _factoringContract().fundInvoices(params, receivers);
    }
}
