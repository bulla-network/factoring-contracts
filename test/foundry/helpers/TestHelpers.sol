// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "contracts/interfaces/IBullaFactoring.sol";
import "./Builders.sol";

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
