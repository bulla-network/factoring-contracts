// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../interfaces/IBullaFactoring.sol";

/// @notice Helpers for packing/unpacking fields on InvoiceApproval that share a storage slot.
/// @dev Keeps the InvoiceApproval tuple arity small enough to avoid via-ir stack-too-deep in the
///      compiler-generated public getter.
library ApprovalPacking {
    uint256 private constant HALF_MASK = type(uint128).max;

    error ProtocolFeeOverflow();
    error InsurancePremiumOverflow();

    function packFees(uint256 protocolFee_, uint256 insurancePremium_) internal pure returns (uint256) {
        if (protocolFee_ > HALF_MASK) revert ProtocolFeeOverflow();
        if (insurancePremium_ > HALF_MASK) revert InsurancePremiumOverflow();
        return (insurancePremium_ << 128) | protocolFee_;
    }

    function protocolFee(IBullaFactoringV2_2.InvoiceApproval memory approval) internal pure returns (uint256) {
        return approval.protocolFeeAndInsurancePremium & HALF_MASK;
    }

    function insurancePremium(IBullaFactoringV2_2.InvoiceApproval memory approval) internal pure returns (uint256) {
        return approval.protocolFeeAndInsurancePremium >> 128;
    }
}
