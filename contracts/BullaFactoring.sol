// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import {console} from "../lib/forge-std/src/console.sol";
import "./interfaces/IInvoiceProviderAdapter.sol";
import "./interfaces/IBullaFactoring.sol";
import "./interfaces/IFactoringVault.sol";
import "./Permissions.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/// @title Bulla Factoring Fund
/// @author @solidoracle
/// @notice Bulla Factoring Fund is a ERC4626 compatible fund that allows for the factoring of invoices
contract BullaFactoringV2 is IBullaFactoringV2, IFactoringFund, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Address of the Bulla DAO, a trusted multisig
    address public bullaDao;
    /// @notice Protocol fee in basis points
    uint16 public protocolFeeBps;
    /// @notice Admin fee in basis points
    uint16 public adminFeeBps;
    /// @notice Accumulated protocol fee balance
    uint256 public protocolFeeBalance;
    /// @notice Accumulated admin fee balance
    uint256 public adminFeeBalance;
    /// @notice Address of the underlying asset token (e.g., USDC)
    IERC20 public assetAddress;
    /// @notice Address of the invoice provider contract adapter
    IInvoiceProviderAdapterV2 public invoiceProviderAdapter;
    /// @notice Address of the underwriter, trusted to approve invoices
    address public underwriter;
    /// @notice Timestamp of the fund's creation
    uint256 public creationTimestamp;
    /// @notice Reserve amount for impairment
    uint256 public impairReserve;
    /// @notice Name of the factoring pool
    string public poolName;
    /// @notice Target yield in basis points
    uint16 public targetYieldBps;

    /// @notice Address of the vault
    IBullaFactoringVault public vault;

    /// @notice Grace period for invoices
    uint256 public gracePeriodDays = 60;

    /// @notice Permissions contracts for factoring
    Permissions public factoringPermissions;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => uint256) public paidInvoicesGain;

    /// Mapping from invoice ID to original creditor's address
    mapping(uint256 => address) public originalCreditors;

    /// Mapping from invoice ID to invoice approval details
    mapping(uint256 => InvoiceApproval) public approvedInvoices;
    /// @notice The duration of invoice approval before it expires
    uint256 public approvalDuration = 1 hours;

    /// Array to hold the IDs of all active invoices
    uint256[] public activeInvoices;

    /// Array to track IDs of paid invoices
    uint256[] private paidInvoicesIds;

    /// Array to track IDs of impaired invoices by fund
    uint256[] private impairedByFundInvoicesIds;

    /// Mapping from invoice ID to impairment details
    mapping(uint256 => ImpairmentDetails) public impairments;

    /// Errors
    error CallerNotUnderwriter();
    error DeductionsExceedsRealisedGains();
    error InvoiceNotApproved();
    error ApprovalExpired();
    error InvoiceCanceled();
    error InvoicePaidAmountChanged();
    error FunctionNotSupported();
    error UnauthorizedFactoring(address caller);
    error UnpaidInvoice();
    error InvoiceNotImpaired();
    error InvoiceAlreadyPaid();
    error InvoiceAlreadyImpairedByFund();
    error CallerNotOriginalCreditor();
    error InvalidPercentage();
    error CallerNotBullaDao();
    error NoFeesToWithdraw();
    error InvalidAddress();
    error ImpairReserveMustBeGreater();
    error InvoiceCreditorChanged();
    error ImpairReserveNotSet();
    error InvoiceCannotBePaid();
    error InvoiceTokenMismatch();
    error InvoiceAlreadyFunded();

    /// @param _asset underlying supported stablecoin asset for deposit 
    /// @param _invoiceProviderAdapter adapter for invoice provider
    /// @param _underwriter address of the underwriter
    constructor(
        IERC20 _asset, 
        IInvoiceProviderAdapterV2 _invoiceProviderAdapter, 
        address _underwriter,
        IBullaFactoringVault _vault,
        Permissions _factoringPermissions,
        address _bullaDao,
        uint16 _protocolFeeBps,
        uint16 _adminFeeBps,
        string memory _poolName,
        uint16 _targetYieldBps
    ) Ownable(msg.sender) {
        if (_protocolFeeBps <= 0 || _protocolFeeBps > 10000) revert InvalidPercentage();
        if (_adminFeeBps <= 0 || _adminFeeBps > 10000) revert InvalidPercentage();

        assetAddress = _asset;
        invoiceProviderAdapter = _invoiceProviderAdapter;
        underwriter = _underwriter;
        factoringPermissions = _factoringPermissions;
        bullaDao = _bullaDao;
        protocolFeeBps = _protocolFeeBps;
        adminFeeBps = _adminFeeBps; 
        creationTimestamp = block.timestamp;
        poolName = _poolName;
        targetYieldBps = _targetYieldBps;
        vault = _vault;
    }

    function underlyingAsset() external view returns (IERC20) {
        return assetAddress;
    }

    function getAccruedInterestForVault() external view returns (uint256) {
        return calculateAccruedProfits();
    }

    /// @notice Approves an invoice for funding, can only be called by the underwriter
    /// @param invoiceId The ID of the invoice to approve
    function approveInvoice(uint256 invoiceId, uint16 _interestApr, uint16 _upfrontBps, uint16 minDaysInterestApplied) public {
        if (_upfrontBps <= 0 || _upfrontBps > 10000) revert InvalidPercentage();
        if (msg.sender != underwriter) revert CallerNotUnderwriter();
        uint256 _validUntil = block.timestamp + approvalDuration;
        IInvoiceProviderAdapterV2.Invoice memory invoiceSnapshot = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoiceSnapshot.invoiceAmount - invoiceSnapshot.paidAmount == 0) revert InvoiceCannotBePaid();
        // if invoice already got approved and funded (creditor/owner of invoice is this contract), do not override storage
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        if (IERC721(invoiceContractAddress).ownerOf(invoiceId) == address(this)) revert InvoiceAlreadyFunded();
        // check claim token is equal to pool token
        address claimToken = invoiceSnapshot.tokenAddress;
        if (claimToken != address(assetAddress)) revert InvoiceTokenMismatch();

        approvedInvoices[invoiceId] = InvoiceApproval({
            approved: true,
            validUntil: _validUntil,
            invoiceSnapshot: invoiceSnapshot,
            fundedTimestamp: 0,
            interestApr: _interestApr,
            upfrontBps: _upfrontBps,
            fundedAmountGross: 0,
            fundedAmountNet: 0,
            minDaysInterestApplied: minDaysInterestApplied,
            initialFullInvoiceAmount: invoiceSnapshot.invoiceAmount,
            initialPaidAmount: invoiceSnapshot.paidAmount,
            protocolFeeBps: protocolFeeBps,
            adminFeeBps: adminFeeBps
        });
        emit InvoiceApproved(invoiceId, _interestApr, _upfrontBps, _validUntil, minDaysInterestApplied);
    }

    /// @notice Calculates the interest, protocol fee and admin fee for a given invoice approval over a specified number of days
    /// @param approval The invoice approval details
    /// @param daysOfInterest The number of days over which interest is calculated
    /// @return interest The calculated interest amount
    /// @return protocolFee The calculated protocol fee amount
    /// @return adminFee The calculated admin fee amount
    function calculateFees(InvoiceApproval memory approval, uint256 daysOfInterest, uint256 currentFullInvoiceAmount) private pure returns (uint256 interest, uint256 protocolFee, uint256 adminFee) {
        uint256 interestAprBps = approval.interestApr;
        uint256 interestAprMbps = interestAprBps * 1000;

        // Calculate the APR discount for the payment period
        // millibips used due to the small nature of the fees
        uint256 interestRateMbps = Math.mulDiv(interestAprMbps, daysOfInterest, 365);

        // calculate the APR discount with protocols fee
        // millibips used due to the small nature of the fees
        uint256 interestAndProtocolFeeMbps = Math.mulDiv(interestRateMbps, (10000 + uint256(approval.protocolFeeBps)), 10000);
        
        // Calculate the admin fee rate
        uint256 adminFeeRateMbps = Math.mulDiv(uint256(approval.adminFeeBps) * 1000, daysOfInterest, 365);
        
        // Calculate the total fee rate Mbps (interest + protocol fee + admin fee)
        uint256 totalFeeRateMbps = interestAndProtocolFeeMbps + adminFeeRateMbps;
        
        // cap total fees to max available to distribute
        // V2 update: what is available to distribute now also includes potential interest on the underlying invoice
        uint256 capTotalFees = currentFullInvoiceAmount - approval.initialPaidAmount - approval.fundedAmountNet;

        // Calculate total fees
        uint256 totalFees = Math.min(capTotalFees, Math.mulDiv(currentFullInvoiceAmount - approval.initialPaidAmount, totalFeeRateMbps, 10_000_000));
        
        // Calculate the interest and protocol fee
        uint256 interestAndProtocolFee = totalFeeRateMbps == 0 ? 0 : Math.mulDiv(totalFees, interestAndProtocolFeeMbps, totalFeeRateMbps);
        
        // Calculate the true interest
        interest = interestAndProtocolFeeMbps == 0 ? 0 : Math.mulDiv(interestAndProtocolFee, interestRateMbps, interestAndProtocolFeeMbps);

        // Calculate true protocol fee
        protocolFee = interestAndProtocolFee - interest;

        // Calculate true admin fee
        adminFee = totalFees - interestAndProtocolFee;

        return (interest, protocolFee, adminFee);
    }

    /// @notice Calculates the kickback amount for a given funded amount allowing early payment
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueProtocolFee The true protocol fee amount
    /// @return trueAdminFee The true admin fee amount
    function calculateKickbackAmount(uint256 invoiceId) public view returns (uint256 kickbackAmount, uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) {
        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? Math.mulDiv(block.timestamp - approval.fundedTimestamp, 1, 1 days, Math.Rounding.Ceil) : 0;
        
        uint256 daysOfInterest = daysSinceFunded = Math.max(daysSinceFunded, approval.minDaysInterestApplied);

        (trueInterest, trueProtocolFee, trueAdminFee) = calculateFees(approval, daysOfInterest, invoice.invoiceAmount);

        // Calculate the total amount that should have been paid to the original creditor
        uint256 totalDueToCreditor = invoice.invoiceAmount - approval.initialPaidAmount - trueAdminFee - trueInterest - trueProtocolFee;

        // Calculate the kickback amount
        kickbackAmount = totalDueToCreditor > approval.fundedAmountNet ? totalDueToCreditor - approval.fundedAmountNet : 0;

        return (kickbackAmount, trueInterest, trueProtocolFee, trueAdminFee);
    }

    /// @notice Calculates the total realized gain or loss from paid and impaired invoices
    /// @return The total realized gain adjusted for losses
    function calculateRealizedGainLoss() public view returns (int256) {
        int256 realizedGains = 0;
        // Consider gains from paid invoices
        for (uint256 i = 0; i < paidInvoicesIds.length; i++) {
            uint256 invoiceId = paidInvoicesIds[i];
            realizedGains += int256(paidInvoicesGain[invoiceId]);
        }

        // Consider losses from impaired invoices by fund
        for (uint256 i = 0; i < impairedByFundInvoicesIds.length; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
            realizedGains += int256(impairments[invoiceId].gainAmount);
            realizedGains -= int256(impairments[invoiceId].lossAmount);
        }

        // Consider losses from impaired invoices in activeInvoices
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            if (isInvoiceImpaired(invoiceId)) {
                uint256 fundedAmount = approvedInvoices[invoiceId].fundedAmountNet;
                realizedGains -= int256(fundedAmount);
            }
        }

        return realizedGains;
    }

    /// @notice Calculates the total accrued profits from all active invoices
    /// @dev Iterates through all active invoices, calculates interest for each and sums the net accrued interest
    /// @return accruedProfits The total net accrued profits across all active invoices
    function calculateAccruedProfits() public view returns (uint256 accruedProfits) {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            
            if(!isInvoiceImpaired(invoiceId)) {
                (,uint256 trueInterest,,) = calculateKickbackAmount(invoiceId);
                accruedProfits += trueInterest;
            }
        }

        return accruedProfits;
    }

    /// @notice Calculates the true fees and net funded amount for a given invoice and factorer's upfront bps, annualised
    /// @param invoiceId The ID of the invoice for which to calculate the fees
    /// @param factorerUpfrontBps The upfront bps specified by the factorer
    /// @return fundedAmountGross The gross amount to be funded to the factorer
    /// @return adminFee The target calculated admin fee
    /// @return targetInterest The calculated interest fee
    /// @return targetProtocolFee The calculated protocol fee
    /// @return netFundedAmount The net amount that will be funded to the factorer after deducting fees
    function calculateTargetFees(uint256 invoiceId, uint16 factorerUpfrontBps) public view returns (uint256 fundedAmountGross, uint256 adminFee, uint256 targetInterest, uint256 targetProtocolFee, uint256 netFundedAmount) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        InvoiceApproval memory approval = approvedInvoices[invoiceId];

        if (!approval.approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approval.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();

        uint256 trueInitialFaceValue = approval.initialFullInvoiceAmount - approval.initialPaidAmount;

        fundedAmountGross = Math.mulDiv(trueInitialFaceValue, factorerUpfrontBps, 10000);

        uint256 daysUntilDue =  Math.mulDiv(invoice.dueDate - block.timestamp, 1, 1 days, Math.Rounding.Ceil);

        /// @dev minDaysInterestApplied is the minimum number of days the invoice can be funded for, set by the underwriter during approval
        daysUntilDue = Math.max(daysUntilDue, approval.minDaysInterestApplied);

        (targetInterest, targetProtocolFee, adminFee) = calculateFees(approval, daysUntilDue, approval.initialFullInvoiceAmount);

        uint256 totalFees = adminFee + targetInterest + targetProtocolFee;
        netFundedAmount = fundedAmountGross - totalFees;

        return (fundedAmountGross, adminFee, targetInterest, targetProtocolFee, netFundedAmount);
    }

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @dev No checks needed for the creditor, as transferFrom will revert unless it gets executed by the nft owner (i.e. claim creditor)
    /// @param invoiceId The ID of the invoice to fund
    /// @param factorerUpfrontBps factorer specified upfront bps
    /// @param receiverAddress Address to receive the funds, if address(0) then funds go to msg.sender
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps, address receiverAddress) external returns(uint256) {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!approvedInvoices[invoiceId].approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approvedInvoices[invoiceId].upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approvedInvoices[invoiceId].validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapterV2.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoicesDetails.isCanceled) revert InvoiceCanceled();
        if (approvedInvoices[invoiceId].invoiceSnapshot.paidAmount != invoicesDetails.paidAmount) revert InvoicePaidAmountChanged();
        if (approvedInvoices[invoiceId].invoiceSnapshot.creditor != invoicesDetails.creditor) revert InvoiceCreditorChanged();

        (uint256 fundedAmountGross,,,, uint256 fundedAmountNet) = calculateTargetFees(invoiceId, factorerUpfrontBps);

        // store values in approvedInvoices
        approvedInvoices[invoiceId].fundedAmountGross = fundedAmountGross;
        approvedInvoices[invoiceId].fundedAmountNet = fundedAmountNet;
        approvedInvoices[invoiceId].fundedTimestamp = block.timestamp;
        // update upfrontBps with what was passed in the arg by the factorer
        approvedInvoices[invoiceId].upfrontBps = factorerUpfrontBps; 

        // Determine the actual receiver address - use msg.sender if receiverAddress is address(0)
        address actualReceiver = receiverAddress == address(0) ? msg.sender : receiverAddress;

        // fund the invoice from vault to the actual receiver
        vault.fundClaim(actualReceiver, invoiceId, fundedAmountNet);

        // transfer invoice nft ownership to vault
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        IERC721(invoiceContractAddress).transferFrom(msg.sender, address(this), invoiceId);

        originalCreditors[invoiceId] = msg.sender;
        activeInvoices.push(invoiceId);
        emit InvoiceFunded(invoiceId, fundedAmountNet, msg.sender);
        return fundedAmountNet;
    }

    /// @notice Provides a view of the pool's status, listing paid and impaired invoices, to be called by Gelato or alike
    /// @return paidInvoices An array of paid invoice IDs
    /// @return impairedInvoices An array of impaired invoice IDs
    function viewPoolStatus() public view override(IBullaFactoringV2, IFactoringFund) returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices) {
        uint256 activeCount = activeInvoices.length;
        uint256 impairedByFundCount = impairedByFundInvoicesIds.length;
        
        paidInvoices = new uint256[](activeCount + impairedByFundCount);
        impairedInvoices = new uint256[](activeCount);
        
        uint256 paidCount = 0;
        uint256 impairedCount = 0;

        // Check active invoices
        for (uint256 i = 0; i < activeCount; i++) {
            uint256 invoiceId = activeInvoices[i];
            
            if (isInvoicePaid(invoiceId)) {
                paidInvoices[paidCount++] = invoiceId;
            } else if (isInvoiceImpaired(invoiceId)) {
                impairedInvoices[impairedCount++] = invoiceId;
            }
        }

        // Check impaired invoices by the fund
        for (uint256 i = 0; i < impairedByFundCount; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
            
            if (isInvoicePaid(invoiceId)) {
                paidInvoices[paidCount++] = invoiceId;
            }
        }

        // Overwrite the length of the arrays
        assembly {
            mstore(paidInvoices, paidCount)
            mstore(impairedInvoices, impairedCount)
        }

        return (paidInvoices, impairedInvoices);
    }

    /// @notice Checks if an invoice is fully paid
    /// @param invoiceId The ID of the invoice to check
    /// @return True if the invoice is fully paid, false otherwise
    function isInvoicePaid(uint256 invoiceId) private view returns (bool) {
        IInvoiceProviderAdapterV2.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        return invoicesDetails.isPaid;
    }

    /// @notice Checks if an invoice is impaired, based on its due date and a grace period
    /// @param invoiceId The ID of the invoice to check
    /// @return True if the invoice is impaired, false otherwise
    function isInvoiceImpaired(uint256 invoiceId) private view returns (bool) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        uint256 DaysAfterDueDate = invoice.dueDate + (gracePeriodDays * 1 days); 
        return block.timestamp > DaysAfterDueDate;
    }

    function getFundedAmount(uint invoiceId) public view returns (uint) {
        return approvedInvoices[invoiceId].fundedAmountNet;
    }
    
    /// @notice Increments the profit, and fee balances for a given invoice
    /// @param invoiceId The ID of the invoice
    /// @param trueInterest The true interest amount for the invoice
    /// @param trueProtocolFee The true protocol fee amount for the invoice
    /// @param trueAdminFee The true admin fee amount for the invoice
    function incrementProfitAndFeeBalances(uint256 invoiceId, uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) private {
        // Add the admin fee to the balance
        adminFeeBalance += trueAdminFee;

        // store factoring gain
        paidInvoicesGain[invoiceId] = trueInterest;

        // Update storage variables
        protocolFeeBalance += trueProtocolFee;

        // Add the invoice ID to the paidInvoicesIds array
        paidInvoicesIds.push(invoiceId);
    }

    /// @notice Reconciles the list of active invoices with those that have been paid, updating the fund's records
    /// @dev This function should be called when viewPoolStatus returns some updates, to ensure accurate accounting
    function reconcileActivePaidInvoices() external {
        (uint256[] memory paidInvoiceIds, ) = viewPoolStatus();

        for (uint256 i = 0; i < paidInvoiceIds.length; i++) {
            uint256 invoiceId = paidInvoiceIds[i];
            InvoiceApproval memory approval = approvedInvoices[invoiceId];
            
            // calculate kickback amount adjusting for true interest, protocol and admin fees
            (uint256 kickbackAmount, uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) = calculateKickbackAmount(invoiceId);

            // payback the vault, principal + interest
            assetAddress.safeTransfer(address(vault), trueInterest + approval.fundedAmountNet);

            // mark the claim as paid
            vault.markClaimAsPaid(invoiceId);

            incrementProfitAndFeeBalances(invoiceId, trueInterest, trueProtocolFee, trueAdminFee);   

            // Disperse kickback amount to the original creditor
            address originalCreditor = originalCreditors[invoiceId];            
            if (kickbackAmount != 0) {
                assetAddress.safeTransfer(originalCreditor, kickbackAmount);
                emit InvoiceKickbackAmountSent(invoiceId, kickbackAmount, originalCreditor);
            }

            // Check if the invoice was previously marked as impaired by the fund
            if (impairments[invoiceId].isImpaired) {
                // Remove the invoice from impaired array
                removeImpairedByFundInvoice(invoiceId);

                // Adjust impairment in fund records
                delete impairments[invoiceId];
            } else {
                // Remove the invoice from activeInvoices array
                removeActivePaidInvoice(invoiceId);   
            }

            emit InvoicePaid(invoiceId, trueInterest, trueProtocolFee, trueAdminFee, approval.fundedAmountNet, kickbackAmount, originalCreditor);
        }
        emit ActivePaidInvoicesReconciled(paidInvoiceIds);
    }

    function removeImpairedByFundInvoice(uint256 invoiceId) private {
        for (uint256 i = 0; i < impairedByFundInvoicesIds.length; i++) {
            if (impairedByFundInvoicesIds[i] == invoiceId) {
                impairedByFundInvoicesIds[i] = impairedByFundInvoicesIds[impairedByFundInvoicesIds.length - 1];
                impairedByFundInvoicesIds.pop();
                break;
            }
        }
    }

    /// @notice Unfactors an invoice, returning the invoice NFT to the original creditor and refunding the funded amount
    /// @param invoiceId The ID of the invoice to unfactor
    function unfactorInvoice(uint256 invoiceId) external {
        if (isInvoicePaid(invoiceId)) revert InvoiceAlreadyPaid();
        address originalCreditor = originalCreditors[invoiceId];
        if (originalCreditor != msg.sender) revert CallerNotOriginalCreditor();

        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        // Calculate the funded amount for the invoice
        uint256 fundedAmount = approval.fundedAmountNet;

        // Calculate the number of days since funding
         uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? Math.mulDiv(block.timestamp - approval.fundedTimestamp, 1, 1 days, Math.Rounding.Ceil) : 0;
        (uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) = calculateFees(approval, daysSinceFunded, invoice.invoiceAmount);
        int256 totalRefundOrPaymentAmount = int256(fundedAmount + trueInterest + trueProtocolFee + trueAdminFee) - int256(getPaymentsOnInvoiceSinceFunding(invoiceId));

        // positive number means the original creditor owes us the amount
        if(totalRefundOrPaymentAmount > 0) {
            // Refund the funded amount to the fund from the original creditor
            assetAddress.safeTransferFrom(originalCreditor, address(this), uint256(totalRefundOrPaymentAmount));
        } else if (totalRefundOrPaymentAmount < 0) {
            // negative number means we owe them
            assetAddress.safeTransfer(originalCreditor, uint256(-totalRefundOrPaymentAmount));
        }

        // pay back the vault, principal + interest
        assetAddress.safeTransfer(address(vault), trueInterest + approval.fundedAmountNet);
        vault.markClaimAsPaid(invoiceId);

        // Transfer the invoice NFT back to the original creditor
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        IERC721(invoiceContractAddress).transferFrom(address(this), originalCreditor, invoiceId);

        // Update the contract's state to reflect the unfactoring
        removeActivePaidInvoice(invoiceId);
        incrementProfitAndFeeBalances(invoiceId, trueInterest, trueProtocolFee, trueAdminFee);

        delete originalCreditors[invoiceId];

        emit InvoiceUnfactored(invoiceId, originalCreditor, totalRefundOrPaymentAmount, trueInterest);
    }

    /// @notice Removes an invoice from the list of active invoices once it has been paid
    /// @param invoiceId The ID of the invoice to remove
    function removeActivePaidInvoice(uint256 invoiceId) private {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            if (activeInvoices[i] == invoiceId) {
                activeInvoices[i] = activeInvoices[activeInvoices.length - 1];
                activeInvoices.pop();
                break;
            }
        }
    }

    function getPaymentsOnInvoiceSinceFunding(uint256 invoiceId) private view returns (uint256) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        // Need to subtract payments since funding start
        uint256 paymentSinceFunding = invoice.paidAmount - approvedInvoices[invoiceId].invoiceSnapshot.paidAmount;

        return paymentSinceFunding;
    }

    /// @notice Calculates the total funded amount for all active invoices.
    /// @return The total funded amount for all active invoices
    function deployedCapitalForActiveInvoicesExcludingImpaired() public view returns (uint256) {
        uint256 deployedCapital = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            uint256 deployedCapitalOfInvoice = (isInvoiceImpaired(invoiceId)) ? 0 : getFundedAmount(invoiceId);
            deployedCapital += deployedCapitalOfInvoice;
        }
        return deployedCapital;
    }

    /// @notice Calculates all payments of active invoices since funding
    /// @return The sum of all payments of active invoices since funding
    function getAllIncomingPaymentsForActiveInvoices() private view returns (uint256) {
        uint256 incomingFunds = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            incomingFunds += getPaymentsOnInvoiceSinceFunding(invoiceId);
        }
        return incomingFunds;
    }

    /// @notice Sums the target fees for all active invoices
    /// @return targetFees The total fees for all active invoices
    function sumTargetFeesForActiveInvoices() private view returns (uint256 targetFees) {
        targetFees = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            targetFees += approvedInvoices[invoiceId].fundedAmountGross - approvedInvoices[invoiceId].fundedAmountNet;
        }
        return targetFees;
    }
    
    /// @notice Sets the grace period in days for determining if an invoice is impaired
    /// @param _days The number of days for the grace period
    /// @dev This function can only be called by the contract owner
    function setGracePeriodDays(uint256 _days) public onlyOwner {
        gracePeriodDays = _days;
        emit GracePeriodDaysChanged(_days);
    }

    /// @notice Sets the duration for which invoice approvals are valid
    /// @param _duration The new duration in seconds
    /// @dev This function can only be called by the contract owner
    function setApprovalDuration(uint256 _duration) public onlyOwner {
        approvalDuration = _duration;
        emit ApprovalDurationChanged(_duration);
    }

    /// @notice Sets a new underwriter for the contract
    /// @param _newUnderwriter The address of the new underwriter
    function setUnderwriter(address _newUnderwriter) public onlyOwner {
        if (_newUnderwriter == address(0)) revert InvalidAddress();
        address oldUnderwriter = underwriter;
        underwriter = _newUnderwriter;
        emit UnderwriterChanged(oldUnderwriter, _newUnderwriter);
    }

    /// @notice Allows the Bulla DAO to withdraw accumulated protocol fees.
    function withdrawProtocolFees() external {
        if (msg.sender != bullaDao) revert CallerNotBullaDao();
        uint256 feeAmount = protocolFeeBalance;
        if (feeAmount == 0) revert NoFeesToWithdraw();
        protocolFeeBalance = 0;
        assetAddress.safeTransfer(bullaDao, feeAmount);
        emit ProtocolFeesWithdrawn(bullaDao, feeAmount);
    }

    /// @notice Allows the Pool Owner to withdraw accumulated admin fees.
    function withdrawAdminFees() onlyOwner public {
        uint256 feeAmount = adminFeeBalance;
        if (feeAmount == 0) revert NoFeesToWithdraw();
        adminFeeBalance = 0;
        assetAddress.safeTransfer(msg.sender, feeAmount);
        emit AdminFeesWithdrawn(msg.sender, feeAmount);
    }

    /// @notice Updates the Bulla DAO address
    /// @param _newBullaDao The new address for the Bulla DAO
    function setBullaDaoAddress(address _newBullaDao) public onlyOwner {
        if (_newBullaDao == address(0)) revert InvalidAddress();
        bullaDao = _newBullaDao;
        emit BullaDaoAddressChanged(bullaDao, _newBullaDao);
    }

    /// @notice Updates the protocol fee in basis points (bps)
    /// @param _newProtocolFeeBps The new protocol fee in basis points
    function setProtocolFeeBps(uint16 _newProtocolFeeBps) public onlyOwner {
        if (_newProtocolFeeBps > 10000) revert InvalidPercentage();
        protocolFeeBps = _newProtocolFeeBps;
        emit ProtocolFeeBpsChanged(protocolFeeBps, _newProtocolFeeBps);
    }

    /// @notice Sets the admin fee in basis points
    /// @param _newAdminFeeBps The new admin fee in basis points
    function setAdminFeeBps(uint16 _newAdminFeeBps) public onlyOwner {
        if (_newAdminFeeBps > 10000) revert InvalidPercentage();
        adminFeeBps = _newAdminFeeBps;
        emit AdminFeeBpsChanged(adminFeeBps, _newAdminFeeBps);
    }

    /// @notice Updates the factoring permissions contract
    /// @param _newFactoringPermissionsAddress The address of the new factoring permissions contract
    function setFactoringPermissions(address _newFactoringPermissionsAddress) public onlyOwner {
        factoringPermissions = Permissions(_newFactoringPermissionsAddress);
        emit FactoringPermissionsChanged(_newFactoringPermissionsAddress);
    }

    /// @notice Sets the impair reserve amount
    /// @param _impairReserve The new impair reserve amount
    function setImpairReserve(uint256 _impairReserve) public onlyOwner {
        if (_impairReserve < impairReserve) revert ImpairReserveMustBeGreater();
        uint256 amountToAdd = _impairReserve - impairReserve;
        assetAddress.safeTransferFrom(msg.sender, address(this), amountToAdd);
        impairReserve = _impairReserve;
        emit ImpairReserveChanged(_impairReserve);
    }

    /// @notice Sets the target yield in basis points
    /// @param _targetYieldBps The new target yield in basis points
    function setTargetYield(uint16 _targetYieldBps) public onlyOwner {
        if (_targetYieldBps > 10000) revert InvalidPercentage();
        targetYieldBps = _targetYieldBps;
        emit TargetYieldChanged(_targetYieldBps);
    }

    /// @notice Retrieves the fund information
    /// @return FundInfo The fund information
    function getFundInfo() external view returns (FundInfo memory) {
        uint256 deployedCapital = deployedCapitalForActiveInvoicesExcludingImpaired();

        return FundInfo({
            name: poolName,
            creationTimestamp: creationTimestamp,
            deployedCapital: deployedCapital,
            adminFeeBps: adminFeeBps,
            impairReserve: impairReserve,
            targetYieldBps: targetYieldBps,
            pnl: calculateRealizedGainLoss()
        });
    }

    /// @notice Impairs an invoice, using the impairment reserve to cover the loss
    /// @param invoiceId The ID of the invoice to impair
    function impairInvoice(uint256 invoiceId) public onlyOwner {
        if (impairReserve == 0) revert ImpairReserveNotSet();
        if (!isInvoiceImpaired(invoiceId)) revert InvoiceNotImpaired();

        if (impairments[invoiceId].isImpaired) {
            revert InvoiceAlreadyImpairedByFund();
        }

        uint256 fundedAmount = approvedInvoices[invoiceId].fundedAmountNet;
        uint256 impairAmount = impairReserve / 2;
        impairReserve -= impairAmount; // incidentially adds impairAmount to fund balance as seen in availableAssets

        // deduct from capital at risk
        removeActivePaidInvoice(invoiceId);

        // send the impair amount to the vault
        assetAddress.safeTransfer(address(vault), impairAmount);
        // mark the claim as impaired in the vault
        vault.markClaimAsImpaired(invoiceId);

        // add to impairedByFundInvoicesIds
        impairedByFundInvoicesIds.push(invoiceId);

        // Record impairment details
        impairments[invoiceId] = ImpairmentDetails({
            gainAmount: impairAmount,
            lossAmount: fundedAmount,
            isImpaired: true
        });

        emit InvoiceImpaired(invoiceId, fundedAmount, impairAmount);
    }
}