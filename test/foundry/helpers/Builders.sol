// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "contracts/interfaces/IBullaFactoring.sol";

contract ApproveInvoiceBuilder {
    uint256 _invoiceId;
    uint16 _targetYieldBps;
    uint16 _spreadBps;
    uint16 _upfrontBps;
    uint256 _initialInvoiceValueOverride;

    function withInvoiceId(uint256 invoiceId) external returns (ApproveInvoiceBuilder) {
        _invoiceId = invoiceId;
        return this;
    }

    function withTargetYieldBps(uint16 targetYieldBps) external returns (ApproveInvoiceBuilder) {
        _targetYieldBps = targetYieldBps;
        return this;
    }

    function withSpreadBps(uint16 spreadBps) external returns (ApproveInvoiceBuilder) {
        _spreadBps = spreadBps;
        return this;
    }

    function withUpfrontBps(uint16 upfrontBps) external returns (ApproveInvoiceBuilder) {
        _upfrontBps = upfrontBps;
        return this;
    }

    function withInitialInvoiceValueOverride(uint256 initialInvoiceValueOverride) external returns (ApproveInvoiceBuilder) {
        _initialInvoiceValueOverride = initialInvoiceValueOverride;
        return this;
    }

    function build() external returns (IBullaFactoringV2_2.ApproveInvoiceParams memory) {
        IBullaFactoringV2_2.ApproveInvoiceParams memory params = IBullaFactoringV2_2.ApproveInvoiceParams({
            invoiceId: _invoiceId,
            targetYieldBps: _targetYieldBps,
            spreadBps: _spreadBps,
            upfrontBps: _upfrontBps,
            initialInvoiceValueOverride: _initialInvoiceValueOverride
        });
        _invoiceId = 0;
        _targetYieldBps = 0;
        _spreadBps = 0;
        _upfrontBps = 0;
        _initialInvoiceValueOverride = 0;
        return params;
    }
}

contract FundInvoiceBuilder {
    uint256 _invoiceId;
    uint16 _factorerUpfrontBps;
    uint8 _receiverAddressIndex;

    function withInvoiceId(uint256 invoiceId) external returns (FundInvoiceBuilder) {
        _invoiceId = invoiceId;
        return this;
    }

    function withFactorerUpfrontBps(uint16 factorerUpfrontBps) external returns (FundInvoiceBuilder) {
        _factorerUpfrontBps = factorerUpfrontBps;
        return this;
    }

    function withReceiverAddressIndex(uint8 receiverAddressIndex) external returns (FundInvoiceBuilder) {
        _receiverAddressIndex = receiverAddressIndex;
        return this;
    }

    function build() external returns (IBullaFactoringV2_2.FundInvoiceParams memory) {
        IBullaFactoringV2_2.FundInvoiceParams memory params = IBullaFactoringV2_2.FundInvoiceParams({
            invoiceId: _invoiceId,
            factorerUpfrontBps: _factorerUpfrontBps,
            receiverAddressIndex: _receiverAddressIndex
        });
        _invoiceId = 0;
        _factorerUpfrontBps = 0;
        _receiverAddressIndex = 0;
        return params;
    }
}
