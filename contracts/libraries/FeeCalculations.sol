// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IInvoiceProviderAdapter.sol";
import "../interfaces/IBullaFactoring.sol";

/// @title Fee Calculations Library
/// @notice Library for calculating various fees in the BullaFactoring contract
/// @dev Uses RAY units (27 decimals) for high-precision per-second interest calculations, inspired by Aave V3
library FeeCalculations {
    // ============ RAY Math Constants (Aave V3 style) ============
    
    /// @notice RAY = 1e27, used for high-precision fixed-point arithmetic
    uint256 internal constant RAY = 1e27;
    
    /// @notice Seconds per year (accounting for leap years using Gregorian calendar average)
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    
    // ============ Per-Second Interest Rate Functions ============
    
    /// @notice Calculates the per-second interest rate in RAY units for a given principal and APR
    /// @dev perSecondRate = (principal * targetYieldBps * RAY) / (SECONDS_PER_YEAR * 10000)
    /// @param principal The principal amount (in token decimals)
    /// @param targetYieldBps The target yield in basis points (e.g., 500 = 5%)
    /// @return perSecondInterestRateRay The per-second interest rate in RAY units
    function calculatePerSecondInterestRateRay(
        uint256 principal,
        uint16 targetYieldBps
    ) internal pure returns (uint256 perSecondInterestRateRay) {
        // Calculate: (principal * targetYieldBps * RAY) / (SECONDS_PER_YEAR * 10000)
        // Use mulDiv to avoid overflow
        perSecondInterestRateRay = Math.mulDiv(
            principal * uint256(targetYieldBps),
            RAY,
            SECONDS_PER_YEAR * 10_000
        );
    }
    
    /// @notice Calculates the accrued interest from a per-second rate and elapsed time
    /// @dev accruedInterest = (perSecondRateRay * seconds) / RAY
    /// @param perSecondInterestRateRay The per-second interest rate in RAY units
    /// @param secondsElapsed The number of seconds elapsed
    /// @return accruedInterest The accrued interest in token decimals
    function calculateAccruedInterest(
        uint256 perSecondInterestRateRay,
        uint256 secondsElapsed
    ) internal pure returns (uint256 accruedInterest) {
        // accruedInterest = perSecondRateRay * secondsElapsed / RAY
        accruedInterest = (perSecondInterestRateRay * secondsElapsed) / RAY;
    }

    /// @notice Calculates all fees for an invoice
    /// @param approval The invoice approval data
    /// @param secondsOfInterest The number of seconds for which interest is calculated
    /// @param invoice The invoice data
    /// @return interest The calculated interest amount
    /// @return spreadAmount The calculated spread amount
    /// @return adminFee The calculated admin fee amount
    /// @return kickbackAmount The calculated kickback amount
    function calculateFees(
        IBullaFactoringV2.InvoiceApproval memory approval, 
        uint256 secondsOfInterest, 
        IInvoiceProviderAdapterV2.Invoice memory invoice
    ) internal pure returns (
        uint256 interest, 
        uint256 spreadAmount,
        uint256 adminFee, 
        uint256 kickbackAmount
    ) {
        // Calculate the APR discount for the payment period
        // millibips used due to the small nature of the fees
        uint256 _targetYieldMbps = Math.mulDiv(uint256(approval.feeParams.targetYieldBps) * 1000, secondsOfInterest, SECONDS_PER_YEAR);
        uint256 spreadRateMbps = Math.mulDiv(uint256(approval.feeParams.spreadBps) * 1000, secondsOfInterest, SECONDS_PER_YEAR);
        
        // Calculate the admin fee rate
        uint256 adminFeeRateMbps = Math.mulDiv(uint256(approval.feeParams.adminFeeBps) * 1000, secondsOfInterest, SECONDS_PER_YEAR);
        
        // Calculate the total fee rate Mbps (base yield + spread + admin fee)
        uint256 totalFeeRateMbps = _targetYieldMbps + spreadRateMbps + adminFeeRateMbps;

        // cap kickback amount to the principal amount
        uint256 capKickbackAmount = approval.initialInvoiceValue > approval.fundedAmountNet ? approval.initialInvoiceValue - approval.fundedAmountNet - approval.protocolFee : 0;
        
        // cap total fees to max available to distribute
        // invoice amount includes interest
        // Handle case where override amount might be higher than invoice amount
        uint256 availableFromInvoice = invoice.invoiceAmount - approval.initialPaidAmount - approval.protocolFee;
        uint256 capTotalFees =
            availableFromInvoice > approval.fundedAmountNet
            ? availableFromInvoice - approval.fundedAmountNet
            : 0;

        uint256 minimumFees = capTotalFees > capKickbackAmount ? capTotalFees - capKickbackAmount : 0;

        // Calculate total fees on the principal amount only
        uint256 totalFees = Math.max(Math.min(capTotalFees, Math.mulDiv(approval.initialInvoiceValue, totalFeeRateMbps, 10_000_000)), minimumFees);
        
        adminFee = totalFeeRateMbps == 0 || totalFees == 0 ? 0 : Math.mulDiv(totalFees, adminFeeRateMbps, totalFeeRateMbps);
        interest = totalFeeRateMbps == 0 || totalFees == 0 ? 0 : Math.mulDiv(totalFees, _targetYieldMbps, totalFeeRateMbps);
        spreadAmount = totalFees - adminFee - interest;

        // Handle case where total fees might exceed available amount from invoice
        uint256 totalDueToCreditor =
            availableFromInvoice > totalFees
            ? availableFromInvoice - totalFees
            : 0;

        kickbackAmount = totalDueToCreditor > approval.fundedAmountNet ? totalDueToCreditor - approval.fundedAmountNet : 0;

        return (interest, spreadAmount, adminFee, kickbackAmount);
    }

    /// @notice Calculates the kickback amount and fees for a given invoice
    /// @param approval The invoice approval data
    /// @param invoice The invoice data
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueSpreadAmount The true spread amount
    /// @return trueAdminFee The true admin fee amount
    function calculateKickbackAmount(
        IBullaFactoringV2.InvoiceApproval memory approval, 
        IInvoiceProviderAdapterV2.Invoice memory invoice
    ) internal view returns (
        uint256 kickbackAmount, 
        uint256 trueInterest, 
        uint256 trueSpreadAmount,
        uint256 trueAdminFee
    ) {
        uint256 secondsOfInterest = (block.timestamp > approval.fundedTimestamp) ? 
            (block.timestamp - approval.fundedTimestamp) : 0;

        (trueInterest, trueSpreadAmount, trueAdminFee, kickbackAmount) = 
            calculateFees(approval, secondsOfInterest, invoice);

        return (kickbackAmount, trueInterest, trueSpreadAmount, trueAdminFee);
    }

    /// @notice Calculates the target fees for an invoice based on funding parameters
    /// @param approval The invoice approval data
    /// @param invoice The invoice data
    /// @param factorerUpfrontBps The upfront bps specified by the factorer
    /// @param protocolFeeBps The protocol fee in basis points (taken off the top)
    /// @return fundedAmountGross The gross amount to be funded to the factorer (includes protocol fee)
    /// @return adminFee The target calculated admin fee
    /// @return targetInterest The calculated interest fee
    /// @return targetSpreadAmount The calculated spread amount
    /// @return protocolFee The protocol fee amount
    /// @return netFundedAmount The net amount that will be funded to the factorer after deducting fees
    function calculateTargetFees(
        IBullaFactoringV2.InvoiceApproval memory approval,
        IInvoiceProviderAdapterV2.Invoice memory invoice,
        uint16 factorerUpfrontBps,
        uint16 protocolFeeBps
    ) internal view returns (
        uint256 fundedAmountGross, 
        uint256 adminFee, 
        uint256 targetInterest, 
        uint256 targetSpreadAmount,
        uint256 protocolFee,
        uint256 netFundedAmount
    ) {
        // Calculate protocol fee (taken off the top)
        protocolFee = Math.mulDiv(approval.initialInvoiceValue, protocolFeeBps, 10000);
        
        // Calculate funded amount gross from the full invoice value (includes protocol fee)
        fundedAmountGross = Math.mulDiv(approval.initialInvoiceValue, factorerUpfrontBps, 10000);

        uint256 secondsUntilDue = approval.invoiceDueDate - block.timestamp;

        (targetInterest, targetSpreadAmount, adminFee, ) = 
            calculateFees(approval, secondsUntilDue, invoice);

        uint256 totalFees = adminFee + targetInterest + targetSpreadAmount + protocolFee;
        netFundedAmount = fundedAmountGross > totalFees ? fundedAmountGross - totalFees : 0;

        return (fundedAmountGross, adminFee, targetInterest, targetSpreadAmount, protocolFee, netFundedAmount);
    }
}
