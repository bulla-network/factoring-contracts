// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import {console} from "../lib/forge-std/src/console.sol";
import "./interfaces/IInvoiceProviderAdapter.sol";
import "./interfaces/IBullaFactoring.sol";
import "./Permissions.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/// @title Bulla Factoring Fund
/// @author @solidoracle
contract BullaFactoring is IBullaFactoring, ERC20, ERC4626, Ownable {
    using Math for uint256;

    address public bullaDao;
    uint16 public protocolFeeBps;
    uint16 public adminFeeBps;
    uint256 public protocolFeeBalance;
    uint256 public adminFeeBalance;
    IERC20 public assetAddress;
    IInvoiceProviderAdapter public invoiceProviderAdapter;
    uint256 private totalDeposits; 
    uint256 private totalWithdrawals;
    address public underwriter;
    uint256 public creationTimestamp;
    uint256 public impairReserve;
    string public poolName;
    uint16 public taxBps;
    uint256 public taxBalance;
    uint16 public targetYieldBps;

    uint256 public SCALING_FACTOR;
    uint256 public gracePeriodDays = 60;

    Permissions public depositPermissions;
    Permissions public factoringPermissions;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => uint256) public paidInvoicesGain;

    /// Mapping from invoice ID to original creditor's address
    mapping(uint256 => address) public originalCreditors;

    mapping(uint256 => InvoiceApproval) public approvedInvoices;
    uint256 public approvalDuration = 1 hours;

    /// Array to hold the IDs of all active invoices
    uint256[] public activeInvoices;

    /// Array to track IDs of paid invoices
    uint256[] private paidInvoicesIds;

    /// Array to track IDs of impaired invoices by fund
    uint256[] private impairedByFundInvoicesIds;

    /// Mapping from invoice ID to impairment details
    mapping(uint256 => ImpairmentDetails) public impairments;

    /// Mapping from invoice ID to tax amount
    mapping(uint256 => uint256) public paidInvoiceTax;

    /// Errors
    // error IncorrectValue(uint256 value, uint256 expectedValue);
    error CallerNotUnderwriter();
    error DeductionsExceedsRealisedGains();
    error InvoiceNotApproved();
    error ApprovalExpired();
    error InvoiceCanceled();
    error InvoicePaidAmountChanged();
    error FunctionNotSupported();
    error UnauthorizedDeposit(address caller);
    error UnauthorizedFactoring(address caller);
    error UnpaidInvoice();
    error InvoiceNotImpaired();
    error InvoiceAlreadyPaid();
    error InvoiceAlreadyImpairedByFund();
    error CallerNotOriginalCreditor();
    error InvalidPercentage();
    error CallerNotBullaDao();
    error NoFeesToWithdraw();
    error FeeWithdrawalFailed();
    error InvalidAddress();
    error NoTaxBalanceToWithdraw();
    error TaxWithdrawalFailed();
    error ImpairReserveMustBeGreater();
    error TransferFailed();
    error InvoiceCreditorChanged();
    error ImpairReserveNotSet();


    /// @param _asset underlying supported stablecoin asset for deposit 
    /// @param _invoiceProviderAdapter adapter for invoice provider
    /// @param _underwriter address of the underwriter
    constructor(
        IERC20 _asset, 
        IInvoiceProviderAdapter _invoiceProviderAdapter, 
        address _underwriter,
        Permissions _depositPermissions,
        Permissions _factoringPermissions,
        address _bullaDao,
        uint16 _protocolFeeBps,
        uint16 _adminFeeBps,
        string memory _poolName,
        uint16 _taxBps,
        uint16 _targetYieldBps,
        string memory _tokenName, 
        string memory _tokenSymbol
    ) ERC20(_tokenName, _tokenSymbol) ERC4626(_asset) Ownable(msg.sender) {
        if (_protocolFeeBps <= 0 || _protocolFeeBps > 10000) revert InvalidPercentage();
        if (_adminFeeBps <= 0 || _adminFeeBps > 10000) revert InvalidPercentage();

        assetAddress = _asset;
        SCALING_FACTOR = 10**uint256(ERC20(address(assetAddress)).decimals());
        invoiceProviderAdapter = _invoiceProviderAdapter;
        underwriter = _underwriter;
        depositPermissions = _depositPermissions;
        factoringPermissions = _factoringPermissions;
        bullaDao = _bullaDao;
        protocolFeeBps = _protocolFeeBps;
        adminFeeBps = _adminFeeBps; 
        creationTimestamp = block.timestamp;
        poolName = _poolName;
        taxBps = _taxBps;
        targetYieldBps = _targetYieldBps;
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

    /// @notice Approves an invoice for funding, can only be called by the underwriter
    /// @param invoiceId The ID of the invoice to approve
    function approveInvoice(uint256 invoiceId, uint16 _interestApr, uint16 _upfrontBps, uint16 minDaysInterestApplied) public {
        if (_upfrontBps <= 0 || _upfrontBps > 10000) revert InvalidPercentage();
        if (msg.sender != underwriter) revert CallerNotUnderwriter();
        uint256 _validUntil = block.timestamp + approvalDuration;
        IInvoiceProviderAdapter.Invoice memory invoiceSnapshot = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        approvedInvoices[invoiceId] = InvoiceApproval({
            approved: true,
            validUntil: _validUntil,
            invoiceSnapshot: invoiceSnapshot,
            fundedTimestamp: 0,
            interestApr: _interestApr,
            upfrontBps: _upfrontBps,
            fundedAmountGross: 0,
            fundedAmountNet: 0,
            adminFee: 0,
            minDaysInterestApplied: minDaysInterestApplied,
            trueFaceValue: invoiceSnapshot.faceValue - invoiceSnapshot.paidAmount
        });
        emit InvoiceApproved(invoiceId, _interestApr, _upfrontBps, _validUntil, minDaysInterestApplied);
    }

    /// @notice Calculates the interest and protocol fee for a given invoice approval over a specified number of days
    /// @param approval The invoice approval details
    /// @param daysOfInterest The number of days over which interest is calculated
    /// @return trueInterest The calculated true interest amount
    /// @return trueProtocolFee The calculated true protocol fee amount
    function calculateInterestAndProtocolFee(InvoiceApproval memory approval, uint256 daysOfInterest) private view returns (uint256 trueInterest, uint256 trueProtocolFee) {
        uint256 interestAprBps = approval.interestApr;
        uint256 interestAprMbps = interestAprBps * 1000;

        // Calculate the true APR discount for the actual payment period
        // millibips used due to the small nature of the fees
        uint256 trueInterestRateMbps = Math.mulDiv(interestAprMbps, daysOfInterest, 365);

        // calculate the true APR discount with protocols fee
        // millibips used due to the small nature of the fees
        uint256 trueInterestAndProtocolFeeMbps = Math.mulDiv(trueInterestRateMbps, (10000 + protocolFeeBps), 10000);
        
        // cap interest to max available to distribute, excluding the targetInterest and targetProtocolFee
        uint256 capInterest = approval.trueFaceValue - approval.fundedAmountNet - approval.adminFee;

        // Calculate the true interest and protocol fee
        uint256 trueInterestAndProtocolFee = Math.min(capInterest, Math.mulDiv(approval.trueFaceValue, trueInterestAndProtocolFeeMbps, 1000_0000));
        
        // Calculate the true interest
        trueInterest = Math.mulDiv(trueInterestAndProtocolFee, trueInterestRateMbps, trueInterestAndProtocolFeeMbps);

        // Calculate true protocol fee
        trueProtocolFee = trueInterestAndProtocolFee - trueInterest;

        return (trueInterest, trueProtocolFee);
    }

    /// @notice Calculates the kickback amount for a given funded amount allowing early payment
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueProtocolFee The true protocol fee amount
    function calculateKickbackAmount(uint256 invoiceId) public view returns (uint256 kickbackAmount, uint256 trueInterest, uint256 trueProtocolFee) {
        InvoiceApproval memory approval = approvedInvoices[invoiceId];
    
        uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? (block.timestamp - approval.fundedTimestamp) / 60 / 60 / 24 : 0;
        uint256 daysOfInterest = daysSinceFunded = Math.max(daysSinceFunded + 1, approval.minDaysInterestApplied);

        (trueInterest, trueProtocolFee) = calculateInterestAndProtocolFee(approval, daysOfInterest);

        // Calculate the total amount that should have been paid to the original creditor
        uint256 totalDueToCreditor = approval.trueFaceValue - approval.adminFee - trueInterest - trueProtocolFee;

        // Calculate the kickback amount
        kickbackAmount = totalDueToCreditor > approval.fundedAmountNet ? totalDueToCreditor - approval.fundedAmountNet : 0;

        return (kickbackAmount, trueInterest, trueProtocolFee);
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

        // Consider gains from impaired invoices by fund
        for (uint256 i = 0; i < impairedByFundInvoicesIds.length; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
            realizedGains += int256(impairments[invoiceId].gainAmount);
        }

        // Consider losses from impaired invoices in activeInvoices
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            if (isInvoiceImpaired(invoiceId)) {
                uint256 fundedAmount = approvedInvoices[invoiceId].fundedAmountNet;
                realizedGains -= int256(fundedAmount);
            }
        }

        // Consider losses from impaired invoices by fund
        for (uint256 i = 0; i < impairedByFundInvoicesIds.length; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
            realizedGains -= int256(impairments[invoiceId].lossAmount);
        }

        return realizedGains;
    }

    /// @notice Calculates the capital account balance, including deposits, withdrawals, and realized gains/losses
    /// @return The calculated capital account balance
    function calculateCapitalAccount() public view returns (uint256) {
        int256 realizedGainLoss = calculateRealizedGainLoss();

        int256 depositsMinusWithdrawals = int256(totalDeposits) - int256(totalWithdrawals);
        int256 capitalAccount = depositsMinusWithdrawals + realizedGainLoss;

        return capitalAccount > 0 ? uint(capitalAccount) : 0;
    }

    /// @notice Calculates the current price per share of the fund
    /// @return The current price per share
    function pricePerShare() public view returns (uint256) {
        uint256 sharesOutstanding = totalSupply();
        if (sharesOutstanding == 0) {
            return SCALING_FACTOR;
        }

        uint256 capitalAccount = calculateCapitalAccount();
        return Math.mulDiv(capitalAccount, SCALING_FACTOR, sharesOutstanding);
    }

    /// @notice Converts an asset amount into shares based on the current price per share
    /// @param assets The amount of assets to convert
    /// @return The equivalent amount of shares
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 currentPricePerShare = pricePerShare();
        return Math.mulDiv(assets, SCALING_FACTOR, currentPricePerShare);
    }

    /// @notice Helper function to handle the logic of depositing assets in exchange for fund shares
    /// @param from The address making the deposit
    /// @param receiver The address to receive the fund shares
    /// @param assets The amount of assets to deposit
    /// @return The number of shares issued for the deposit
    function _deposit(address from, address receiver, uint256 assets) private returns (uint256) {
        if (!depositPermissions.isAllowed(from)) revert UnauthorizedDeposit(from);
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 sharesOutstanding = totalSupply();
        assetAddress.transferFrom(from, address(this), assets);

        uint256 shares;
        if(sharesOutstanding == 0) {
            shares = assets;
        } else {
            shares = Math.mulDiv(assets * SCALING_FACTOR, sharesOutstanding, capitalAccount) / SCALING_FACTOR;
        }

        _mint(receiver, shares);

        totalDeposits += assets;
        return shares;
    }

    /// @notice Allows for the deposit of assets in exchange for fund shares with an attachment
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the fund shares
    /// @param attachment The attachment data for the deposit
    /// @return The number of shares issued for the deposit
    function depositWithAttachment(uint256 assets, address receiver, Multihash calldata attachment) public returns (uint256) {
        uint256 shares = _deposit(_msgSender(), receiver, assets);
        emit DepositMadeWithAttachment(_msgSender(), assets, shares, attachment);
        return shares;
    }

    /// @notice Allows for the deposit of assets in exchange for fund shares
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the fund shares
    /// @return The number of shares issued for the deposit
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = _deposit(_msgSender(), receiver, assets);
        emit DepositMade(_msgSender(), assets, shares);
        return shares;
    }

    /// @notice Calculates the true fees and net funded amount for a given invoice and factorer's upfront bps, annualised
    /// @param invoiceId The ID of the invoice for which to calculate the fees
    /// @param factorerUpfrontBps The upfront bps specified by the factorer
    /// @return fundedAmountGross The gross amount to be funded to the factorer
    /// @return adminFee The calculated admin fee
    /// @return targetInterest The calculated interest fee
    /// @return targetProtocolFee The calculated protocol fee
    /// @return netFundedAmount The net amount that will be funded to the factorer after deducting fees
    function calculateTargetFees(uint256 invoiceId, uint16 factorerUpfrontBps) public view returns (uint256 fundedAmountGross, uint256 adminFee, uint256 targetInterest, uint256 targetProtocolFee, uint256 netFundedAmount) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        InvoiceApproval memory approval = approvedInvoices[invoiceId];

        if (!approval.approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approval.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();

        uint256 trueFaceValue = approval.trueFaceValue;

        fundedAmountGross = Math.mulDiv(trueFaceValue, factorerUpfrontBps, 10000);

        uint256 daysUntilDue = (invoice.dueDate - block.timestamp) / 60 / 60 / 24;
        /// @dev minDaysInterestApplied is the minimum number of days the invoice can be funded for, set by the underwriter during approval
        daysUntilDue = Math.max(daysUntilDue, approval.minDaysInterestApplied);

        uint256 adminFeeRate = Math.mulDiv(trueFaceValue, adminFeeBps, 10000);
        adminFee = Math.mulDiv(adminFeeRate, daysUntilDue, 365);

        uint256 targetInterestRate = Math.mulDiv(approval.interestApr, daysUntilDue, 365);
        targetInterest = Math.mulDiv(trueFaceValue, targetInterestRate, 10000);

        targetProtocolFee = Math.mulDiv(targetInterest, protocolFeeBps, 10000);

        uint256 totalFees = adminFee + targetInterest + targetProtocolFee;
        netFundedAmount = fundedAmountGross - totalFees;

        return (fundedAmountGross, adminFee, targetInterest, targetProtocolFee, netFundedAmount);
    }

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @param invoiceId The ID of the invoice to fund
    /// @param factorerUpfrontBps factorer specified upfront bps
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps) public returns(uint256) {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!approvedInvoices[invoiceId].approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approvedInvoices[invoiceId].upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approvedInvoices[invoiceId].validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapter.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoicesDetails.isCanceled) revert InvoiceCanceled();
        if (approvedInvoices[invoiceId].invoiceSnapshot.paidAmount != invoicesDetails.paidAmount) revert InvoicePaidAmountChanged();
        if (approvedInvoices[invoiceId].invoiceSnapshot.creditor != invoicesDetails.creditor) revert InvoiceCreditorChanged();

        (uint256 fundedAmountGross, uint256 adminFee, , , uint256 fundedAmountNet) = calculateTargetFees(invoiceId, factorerUpfrontBps);

        // store values in approvedInvoices
        approvedInvoices[invoiceId].fundedAmountGross = fundedAmountGross;
        approvedInvoices[invoiceId].fundedAmountNet = fundedAmountNet;
        approvedInvoices[invoiceId].fundedTimestamp = block.timestamp;
        approvedInvoices[invoiceId].adminFee = adminFee;
        // update upfrontBps with what was passed in the arg by the factorer
        approvedInvoices[invoiceId].upfrontBps = factorerUpfrontBps; 

        // transfer net funded amount to caller
        assetAddress.transfer(msg.sender, fundedAmountNet);

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
    function viewPoolStatus() public view returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices) {
        uint256 activeCount = activeInvoices.length;
        uint256 impairedByFundCount = impairedByFundInvoicesIds.length;
        uint256[] memory tempPaidInvoices = new uint256[](activeCount + impairedByFundCount);
        uint256[] memory tempImpairedInvoices = new uint256[](activeCount);
        uint256 paidCount = 0;
        uint256 impairedCount = 0;

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 invoiceId = activeInvoices[i];
 
            if (isInvoicePaid(invoiceId)) {
                tempPaidInvoices[paidCount] = invoiceId;
                paidCount++;
            } else if (isInvoiceImpaired(invoiceId)) {
                tempImpairedInvoices[impairedCount] = invoiceId;
                impairedCount++;
            }
        }

        // check if any of the impaired invoices by the fund got paid
        for (uint256 i = 0; i < impairedByFundCount; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
 
            if (isInvoicePaid(invoiceId)) {
                tempPaidInvoices[paidCount] = invoiceId;
                paidCount++;
            } 
        }
    
        paidInvoices = new uint256[](paidCount);
        impairedInvoices = new uint256[](impairedCount);

        for (uint256 i = 0; i < paidCount; i++) {
            paidInvoices[i] = tempPaidInvoices[i];
        }

        for (uint256 i = 0; i < impairedCount; i++) {
            impairedInvoices[i] = tempImpairedInvoices[i];
        }

        return (paidInvoices, impairedInvoices);
    }

    /// @notice Checks if an invoice is fully paid
    /// @param invoiceId The ID of the invoice to check
    /// @return True if the invoice is fully paid, false otherwise
    function isInvoicePaid(uint256 invoiceId) private view returns (bool) {
        IInvoiceProviderAdapter.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        return invoicesDetails.faceValue == invoicesDetails.paidAmount;
    }

    /// @notice Checks if an invoice is impaired, based on its due date and a grace period
    /// @param invoiceId The ID of the invoice to check
    /// @return True if the invoice is impaired, false otherwise
    function isInvoiceImpaired(uint256 invoiceId) private view returns (bool) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        uint256 DaysAfterDueDate = invoice.dueDate + (gracePeriodDays * 1 days); 
        return block.timestamp > DaysAfterDueDate;
    }

    function getFundedAmount(uint invoiceId) public view returns (uint) {
        return approvedInvoices[invoiceId].fundedAmountNet;
    }
    
    /// @notice Increments the profit, tax, and fee balances for a given invoice
    /// @param invoiceId The ID of the invoice
    /// @param trueInterest The true interest amount for the invoice
    /// @param trueProtocolFee The true protocol fee amount for the invoice
    function incrementProfitTaxAndFeeBalances(uint256 invoiceId, uint256 trueInterest, uint256 trueProtocolFee) private {
        // Add the admin fee to the balance
        adminFeeBalance += approvedInvoices[invoiceId].adminFee;
        
        uint256 taxAmount = calculateTax(trueInterest);

        // store factoring gain
        paidInvoicesGain[invoiceId] = trueInterest - taxAmount;

        // Update storage variables
        paidInvoiceTax[invoiceId] = taxAmount;
        taxBalance += taxAmount;
        protocolFeeBalance += trueProtocolFee;

        // Add the invoice ID to the paidInvoicesIds array
        paidInvoicesIds.push(invoiceId);
    }

    /// @notice Reconciles the list of active invoices with those that have been paid, updating the fund's records
    /// @dev This function should be called when viewPoolStatus returns some updates, to ensure accurate accounting
    function reconcileActivePaidInvoices() public {
        (uint256[] memory paidInvoiceIds, ) = viewPoolStatus();

        for (uint256 i = 0; i < paidInvoiceIds.length; i++) {
            uint256 invoiceId = paidInvoiceIds[i];
            
            // calculate kickback amount adjusting for true interest and fees
            (uint256 kickbackAmount, uint256 trueInterest , uint256 trueProtocolFee) = calculateKickbackAmount(invoiceId);

            incrementProfitTaxAndFeeBalances(invoiceId, trueInterest, trueProtocolFee);

            // Disperse kickback amount to the original creditor
            address originalCreditor = originalCreditors[invoiceId];            
            if (kickbackAmount != 0) {
                require(assetAddress.transfer(originalCreditor, kickbackAmount), "Kickback transfer failed");
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

            InvoiceApproval memory approval = approvedInvoices[invoiceId];
            emit InvoicePaid(invoiceId, trueInterest, trueProtocolFee, approval.adminFee, approval.fundedAmountNet, kickbackAmount, originalCreditor);
        }
        emit ActivePaidInvoicesReconciled(paidInvoiceIds);
    }

    /// @notice Calculates the tax amount based on a specified payment amount and the current tax basis points (bps).
    /// @param amount The amount of the payment on which tax is to be calculated.
    /// @return The calculated tax amount.
    function calculateTax(uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, taxBps * 1000, 1_000_000);
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
    function unfactorInvoice(uint256 invoiceId) public {
        if (isInvoicePaid(invoiceId)) revert InvoiceAlreadyPaid();
        address originalCreditor = originalCreditors[invoiceId];
        if (originalCreditor != msg.sender) revert CallerNotOriginalCreditor();

        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        // Calculate the funded amount for the invoice
        uint256 fundedAmount = approval.fundedAmountNet;

        // Calculate the number of days since funding
        uint256 daysSinceFunding = (block.timestamp - approval.fundedTimestamp) / 60 / 60 / 24;
        uint256 daysOfInterestToCharge = daysSinceFunding + 1;
        
        (uint256 trueInterest, uint256 trueProtocolFee) = calculateInterestAndProtocolFee(approval, daysOfInterestToCharge);
        uint256 totalRefundAmount = fundedAmount + trueInterest + trueProtocolFee + approval.adminFee;

        // Refund the funded amount to the fund from the original creditor
        require(assetAddress.transferFrom(originalCreditor, address(this), totalRefundAmount), "Refund transfer failed");

        // Transfer the invoice NFT back to the original creditor
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        IERC721(invoiceContractAddress).transferFrom(address(this), originalCreditor, invoiceId);

        // Update the contract's state to reflect the unfactoring
        removeActivePaidInvoice(invoiceId);
        incrementProfitTaxAndFeeBalances(invoiceId, trueInterest, trueProtocolFee);

        delete originalCreditors[invoiceId];

        emit InvoiceUnfactored(invoiceId, originalCreditor, totalRefundAmount, trueInterest);
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
    /// @notice Calculates the total funded amount for all active invoices
    /// @return The total funded amount for all active invoices
    function totalFundedAmountForActiveInvoices() public view returns (uint256) {
        uint256 totalFunded = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            totalFunded += getFundedAmount(invoiceId);
        }
        return totalFunded;
    }

    /// @notice Sums the target fees for all active invoices
    /// @return targetFees The total fees for all active invoices
    function sumTargetFeesForActiveInvoices() public view returns (uint256 targetFees) {
        targetFees = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            targetFees += approvedInvoices[invoiceId].fundedAmountGross - approvedInvoices[invoiceId].fundedAmountNet;
        }
        return targetFees;
    }

    /// @notice Calculates the available assets in the fund net of fees, impair reserve and tax
    /// @return The amount of assets available for withdrawal or new investments, excluding funds allocated to active invoices
    function availableAssets() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        uint256 realisedAndTargetFees = sumTargetFeesForActiveInvoices() + protocolFeeBalance + adminFeeBalance;
        return totalAssetsInFund - realisedAndTargetFees - impairReserve - taxBalance;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() public view returns (uint256) {
        uint256 availableAssetAmount = availableAssets();
        uint256 capitalAccount = calculateCapitalAccount();

        if (capitalAccount == 0) {
            return 0;
        }

        uint256 scaledAvailableAssets = availableAssetAmount * SCALING_FACTOR;
        uint256 scaledCapitalAccount = capitalAccount * SCALING_FACTOR;

        uint256 maxWithdrawableShares = Math.mulDiv(scaledAvailableAssets, totalSupply(), scaledCapitalAccount);
        return maxWithdrawableShares;
    }

    /// @notice Helper function to handle the logic of redeeming shares for underlying assets
    /// @param from The address initiating the redemption
    /// @param receiver The address to receive the redeemed assets
    /// @param owner The owner of the shares being redeemed
    /// @param shares The number of shares to redeem
    /// @return The amount of assets redeemed
    function _redeem(address from, address receiver, address owner, uint256 shares) private returns (uint256) {
        uint256 maxWithdrawableShares = maxRedeem();
        uint256 assets;
        if (shares > maxWithdrawableShares) {
            uint256 maxWithdrawableAmount = availableAssets();   
            _withdraw(from, receiver, owner, maxWithdrawableAmount, maxWithdrawableShares);
            assets = maxWithdrawableAmount;
        } else {
            uint256 scaledShares = shares * SCALING_FACTOR;
            uint256 capitalAccount = calculateCapitalAccount();
            uint256 scaledCapitalAccount = capitalAccount * SCALING_FACTOR;
            uint assetsScaled = Math.mulDiv(scaledShares , scaledCapitalAccount , totalSupply());
            assets = assetsScaled / SCALING_FACTOR / SCALING_FACTOR;
            _withdraw(from, receiver, owner, assets, shares);
        }
        totalWithdrawals += assets;
        return assets;
    }

    /// @notice Redeems shares for underlying assets with an attachment, transferring the assets to the specified receiver
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param owner The owner of the shares being redeemed
    /// @param attachment The attachment data for the redemption
    /// @return The amount of assets redeemed
    function redeemWithAttachment(uint256 shares, address receiver, address owner, Multihash calldata attachment) public returns (uint256) {
        uint256 assets = _redeem(_msgSender(), receiver, owner, shares);
        emit SharesRedeemedWithAttachment(_msgSender(), shares, assets, attachment);
        return assets;
    }

    /// @notice Redeems shares for underlying assets, transferring the assets to the specified receiver
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param owner The owner of the shares being redeemed
    /// @return The amount of assets redeemed
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 assets = _redeem(_msgSender(), receiver, owner, shares);
        emit SharesRedeemed(_msgSender(), shares, assets);
        return assets;
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
    function withdrawProtocolFees() public {
        if (msg.sender != bullaDao) revert CallerNotBullaDao();
        uint256 feeAmount = protocolFeeBalance;
        if (feeAmount == 0) revert NoFeesToWithdraw();
        protocolFeeBalance = 0;
        bool success = assetAddress.transfer(bullaDao, feeAmount);
        if (!success) revert FeeWithdrawalFailed();
        emit ProtocolFeesWithdrawn(bullaDao, feeAmount);
    }

    /// @notice Allows the Pool Owner to withdraw accumulated admin fees.
    function withdrawAdminFees() onlyOwner public {
        uint256 feeAmount = adminFeeBalance;
        if (feeAmount == 0) revert NoFeesToWithdraw();
        adminFeeBalance = 0;
        bool success = assetAddress.transfer(msg.sender, feeAmount);
        if (!success) revert FeeWithdrawalFailed();
        emit AdminFeesWithdrawn(msg.sender, feeAmount);
    }

    /// @notice Withdraws the accumulated tax balance to the pool owner
    /// @dev This function can only be called by the contract owner
    function withdrawTaxBalance() public onlyOwner {
        if (taxBalance == 0) revert NoTaxBalanceToWithdraw();
        uint256 amountToWithdraw = taxBalance;
        taxBalance = 0;
        bool success = assetAddress.transfer(msg.sender, amountToWithdraw);
        if (!success) revert TaxWithdrawalFailed();
        emit TaxBalanceWithdrawn(msg.sender, amountToWithdraw);
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
        if (_newProtocolFeeBps <= 0 || _newProtocolFeeBps > 10000) revert InvalidPercentage();
        protocolFeeBps = _newProtocolFeeBps;
        emit ProtocolFeeBpsChanged(protocolFeeBps, _newProtocolFeeBps);
    }

    /// @notice Sets the admin fee in basis points
    /// @param _newAdminFeeBps The new admin fee in basis points
    function setAdminFeeBps(uint16 _newAdminFeeBps) public onlyOwner {
        if (_newAdminFeeBps <= 0 || _newAdminFeeBps > 10000) revert InvalidPercentage();
        adminFeeBps = _newAdminFeeBps;
        emit AdminFeeBpsChanged(adminFeeBps, _newAdminFeeBps);
    }

    /// @notice Sets the tax basis points (bps)
    /// @param _newTaxBps The new tax rate in basis points
    /// @dev This function can only be called by the contract owner
    function setTaxBps(uint16 _newTaxBps) public onlyOwner {
        if (_newTaxBps < 0 || _newTaxBps > 10000) revert InvalidPercentage();
        taxBps = _newTaxBps;
        emit TaxBpsChanged(taxBps, _newTaxBps);
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert FunctionNotSupported();
    }

    function mint(uint256, address) public pure override returns (uint256){
        revert FunctionNotSupported();
    }

    /// @notice Updates the deposit permissions contract
    /// @param _newDepositPermissionsAddress The new deposit permissions contract address
    function setDepositPermissions(address _newDepositPermissionsAddress) public onlyOwner {
        depositPermissions = Permissions(_newDepositPermissionsAddress);
        emit DepositPermissionsChanged(_newDepositPermissionsAddress);
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
        bool success = assetAddress.transferFrom(msg.sender, address(this), amountToAdd);
        if (!success) revert TransferFailed();
        impairReserve = _impairReserve;
        emit ImpairReserveChanged(_impairReserve);
    }

    /// @notice Sets the target yield in basis points
    /// @param _targetYieldBps The new target yield in basis points
    function setTargetYield(uint16 _targetYieldBps) public onlyOwner {
        if (_targetYieldBps < 0 || _targetYieldBps > 10000) revert InvalidPercentage();
        targetYieldBps = _targetYieldBps;
        emit TargetYieldChanged(_targetYieldBps);
    }

    /// @notice Sets a new invoice provider adapter
    /// @param _newInvoiceProviderAdapter The address of the new invoice provider adapter
    function setInvoiceProviderAdapter(IInvoiceProviderAdapter _newInvoiceProviderAdapter) public onlyOwner {
        invoiceProviderAdapter = _newInvoiceProviderAdapter;
        emit InvoiceProviderAdapterChanged(_newInvoiceProviderAdapter);
    }

    function getFundInfo() public view returns (FundInfo memory) {
        uint256 fundBalance = availableAssets();
        uint256 deployedCapital = totalFundedAmountForActiveInvoices();
        int256 realizedGain = calculateRealizedGainLoss();
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 price = pricePerShare();
        uint256 tokensAvailableForRedemption = maxRedeem();

        return FundInfo({
            name: poolName,
            creationTimestamp: creationTimestamp,
            fundBalance: fundBalance,
            deployedCapital: deployedCapital,
            realizedGain: realizedGain,
            capitalAccount: capitalAccount,
            price: price,
            tokensAvailableForRedemption: tokensAvailableForRedemption,
            adminFeeBps: adminFeeBps,
            impairReserve: impairReserve,
            targetYieldBps: targetYieldBps
        });
    }

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