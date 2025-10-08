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
import "./interfaces/IRedemptionQueue.sol";
import "./Permissions.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IBullaFrendLendV2, LoanRequestParams} from "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {InterestConfig} from "@bulla/contracts-v2/src/libraries/CompoundInterestLib.sol";
import "./RedemptionQueue.sol";

/// @title Bulla Factoring Fund
/// @author @solidoracle
/// @notice Bulla Factoring Fund is a ERC4626 compatible fund that allows for the factoring of invoices
contract BullaFactoringV2 is IBullaFactoringV2, ERC20, ERC4626, Ownable {
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
    /// @notice Accumulated spread gains balance
    uint256 public spreadGainsBalance;
    /// @notice Address of the underlying asset token (e.g., USDC)
    IERC20 public assetAddress;
    /// @notice Address of the invoice provider contract adapter
    IInvoiceProviderAdapterV2 public invoiceProviderAdapter;
    uint256 private totalDeposits; 
    uint256 private totalWithdrawals;
    /// @notice Address of the bulla frendlend contract
    IBullaFrendLendV2 public bullaFrendLend;
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

    /// @notice Grace period for invoices
    uint256 public gracePeriodDays = 60;

    /// @notice Permissions contracts for deposit and factoring
    Permissions public depositPermissions;
    Permissions public redeemPermissions;
    Permissions public factoringPermissions;

    /// @notice Redemption queue contract for handling queued redemptions
    IRedemptionQueue public redemptionQueue;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => uint256) public paidInvoicesGain;

    /// Mapping of paid invoices ID to track spread gains, that belong to pool owner and are not part of the pool's yield
    mapping(uint256 => uint256) public paidInvoicesSpreadGain;

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

    /// Mapping from loan offer ID to pending loan offer details
    mapping(uint256 => PendingLoanOfferInfo) public pendingLoanOffersByLoanOfferId;

    /// Array to track IDs of pending loan offers
    uint256[] public pendingLoanOffersIds;

    /// Errors
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
    error CallerNotBullaFrendLend();
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
    error LoanOfferNotExists();
    error LoanOfferAlreadyAccepted();
    error InsufficientFunds(uint256 available, uint256 required);
    error RedemptionQueueNotEmpty();
    error ReconciliationNeeded();

    /// @param _asset underlying supported stablecoin asset for deposit 
    /// @param _invoiceProviderAdapter adapter for invoice provider
    /// @param _underwriter address of the underwriter
    constructor(
        IERC20 _asset, 
        IInvoiceProviderAdapterV2 _invoiceProviderAdapter, 
        IBullaFrendLendV2 _bullaFrendLend,
        address _underwriter,
        Permissions _depositPermissions,
        Permissions _redeemPermissions,
        Permissions _factoringPermissions,
        address _bullaDao,
        uint16 _protocolFeeBps,
        uint16 _adminFeeBps,
        string memory _poolName,
        uint16 _targetYieldBps,
        string memory _tokenName, 
        string memory _tokenSymbol
    ) ERC20(_tokenName, _tokenSymbol) ERC4626(_asset) Ownable(_msgSender()) {
        if (_protocolFeeBps <= 0 || _protocolFeeBps > 10000) revert InvalidPercentage();
        if (_adminFeeBps <= 0 || _adminFeeBps > 10000) revert InvalidPercentage();

        assetAddress = _asset;
        invoiceProviderAdapter = _invoiceProviderAdapter;
        bullaFrendLend = _bullaFrendLend;
        underwriter = _underwriter;
        depositPermissions = _depositPermissions;
        redeemPermissions = _redeemPermissions;
        factoringPermissions = _factoringPermissions;
        bullaDao = _bullaDao;
        protocolFeeBps = _protocolFeeBps;
        adminFeeBps = _adminFeeBps; 
        creationTimestamp = block.timestamp;
        poolName = _poolName;
        targetYieldBps = _targetYieldBps;
        redemptionQueue = new RedemptionQueue(msg.sender, address(this));
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

    /// @notice The underwriter approves a loan that was requested by a user
    /// @dev This function is called by the underwriter to approve a loan that was requested by a user
    /// @param debtor The address of the debtor
    /// @param _targetYieldBps The target yield in basis points
    /// @param spreadBps The spread in basis points to add on top of target yield
    /// @param principalAmount The principal amount of the loan
    /// @param termLength The term length of the loan
    /// @param numberOfPeriodsPerYear The number of periods per year
    function offerLoan(address debtor, uint16 _targetYieldBps, uint16 spreadBps, uint256 principalAmount, uint256 termLength, uint16 numberOfPeriodsPerYear, string memory description)
        external returns (uint256 loanOfferId) {
        if (msg.sender != underwriter) revert CallerNotUnderwriter();

        LoanRequestParams memory loanRequestParams = LoanRequestParams({
            termLength: termLength,
            interestConfig: InterestConfig({
                interestRateBps: _targetYieldBps + spreadBps + adminFeeBps + protocolFeeBps,
                numberOfPeriodsPerYear: numberOfPeriodsPerYear
            }),
            loanAmount: principalAmount,
            creditor: address(this),
            debtor: debtor,
            description: description,
            token: address(assetAddress),
            impairmentGracePeriod: gracePeriodDays * 1 days,
            expiresAt: block.timestamp + approvalDuration,
            callbackContract: address(this),
            callbackSelector: this.onLoanOfferAccepted.selector
        });

        assetAddress.safeIncreaseAllowance(address(bullaFrendLend), principalAmount);
        loanOfferId = bullaFrendLend.offerLoan(loanRequestParams);

        pendingLoanOffersByLoanOfferId[loanOfferId] = PendingLoanOfferInfo({
            exists: true,
            feeParams: FeeParams({
                spreadBps: spreadBps,
                upfrontBps: 100_00,
                protocolFeeBps: protocolFeeBps,
                adminFeeBps: adminFeeBps,
                minDaysInterestApplied: 0,
                targetYieldBps: _targetYieldBps
            }),
            principalAmount: principalAmount,
            termLength: termLength,
            offeredAt: block.timestamp
        });

        pendingLoanOffersIds.push(loanOfferId);

        return loanOfferId;
    }

    /// @notice Callback function called when a loan offer is accepted
    /// @dev This function is called by the bulla frendlend contract when a loan offer is accepted
    /// @param loanOfferId The ID of the loan offer
    /// @param loanId The ID of the loan
    function onLoanOfferAccepted(uint256 loanOfferId, uint256 loanId) external {
        if (msg.sender != address(bullaFrendLend)) revert CallerNotBullaFrendLend();
        PendingLoanOfferInfo memory pendingLoanOffer = pendingLoanOffersByLoanOfferId[loanOfferId];
        if (!pendingLoanOffer.exists) revert LoanOfferNotExists();
        if (approvedInvoices[loanId].approved) revert LoanOfferAlreadyAccepted();
        if (!redemptionQueue.isQueueEmpty()) revert RedemptionQueueNotEmpty();

        // even though the funds have left, `totalAssets` only updates once the invoice has been added as an active invoice
        // which reduces totalAssets
        uint256 _totalAssets = totalAssets();
        if (_totalAssets < pendingLoanOffer.principalAmount) revert InsufficientFunds(_totalAssets, pendingLoanOffer.principalAmount);

        // We no longer force having an empty queue because if the queue is non-empty,
        // it means there's no cash in the pool anyways, and
        // the frendlend will fail before even getting to this function

        pendingLoanOffersByLoanOfferId[loanOfferId].exists = false;
        removePendingLoanOffer(loanOfferId);

        approvedInvoices[loanId] = InvoiceApproval({
            approved: true,
            validUntil: pendingLoanOffer.offeredAt,
            fundedTimestamp: block.timestamp,
            feeParams: pendingLoanOffer.feeParams,
            fundedAmountGross: pendingLoanOffer.principalAmount,
            fundedAmountNet: pendingLoanOffer.principalAmount,
            initialInvoiceValue: pendingLoanOffer.principalAmount,
            initialPaidAmount: 0,
            invoiceDueDate: block.timestamp + pendingLoanOffer.termLength,
            receiverAddress: address(this),
            creditor: address(this)
        });

        originalCreditors[loanId] = address(this);
        activeInvoices.push(loanId);
        invoiceProviderAdapter.initializeInvoice(loanId);

        emit InvoiceFunded(loanId, pendingLoanOffer.principalAmount, address(this), block.timestamp + pendingLoanOffer.termLength, pendingLoanOffer.feeParams.upfrontBps);
    }

    /// @notice Approves an invoice for funding, can only be called by the underwriter
    /// @param invoiceId The ID of the invoice to approve
    /// @param _targetYieldBps The target yield in basis points
    /// @param _spreadBps The spread in basis points to add on top of target yield
    /// @param _upfrontBps The maximum upfront percentage the factorer can request
    /// @param minDaysInterestApplied The minimum number of days interest must be applied
    /// @param _initialInvoiceValueOverride The initial invoice value to override the invoice amount. For example in cases of loans or bonds.
    function approveInvoice(uint256 invoiceId, uint16 _targetYieldBps, uint16 _spreadBps, uint16 _upfrontBps, uint16 minDaysInterestApplied, uint256 _initialInvoiceValueOverride) public {
        if (_upfrontBps <= 0 || _upfrontBps > 10000) revert InvalidPercentage();
        if (msg.sender != underwriter) revert CallerNotUnderwriter();
        uint256 _validUntil = block.timestamp + approvalDuration;
        invoiceProviderAdapter.initializeInvoice(invoiceId);
        IInvoiceProviderAdapterV2.Invoice memory invoiceSnapshot = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoiceSnapshot.invoiceAmount - invoiceSnapshot.paidAmount == 0) revert InvoiceCannotBePaid();
        // if invoice already got approved and funded (creditor/owner of invoice is this contract), do not override storage
        // we assume that invoices are always from the bulla protocol and the creditor is always the NFT owner
        if (invoiceSnapshot.creditor == address(this)) revert InvoiceAlreadyFunded();
        // check claim token is equal to pool token
        address claimToken = invoiceSnapshot.tokenAddress;
        if (claimToken != address(assetAddress)) revert InvoiceTokenMismatch();

        FeeParams memory feeParams = FeeParams({
            targetYieldBps: _targetYieldBps,
            spreadBps: _spreadBps,
            upfrontBps: _upfrontBps,
            protocolFeeBps: protocolFeeBps,
            adminFeeBps: adminFeeBps,
            minDaysInterestApplied: minDaysInterestApplied
        });

        approvedInvoices[invoiceId] = InvoiceApproval({
            approved: true,
            validUntil: _validUntil,
            creditor: invoiceSnapshot.creditor,
            fundedTimestamp: 0,
            feeParams: feeParams,
            fundedAmountGross: 0,
            fundedAmountNet: 0,
            initialInvoiceValue: _initialInvoiceValueOverride != 0 ? _initialInvoiceValueOverride : invoiceSnapshot.invoiceAmount - invoiceSnapshot.paidAmount,
            initialPaidAmount: invoiceSnapshot.paidAmount,
            receiverAddress: address(0),
            invoiceDueDate: invoiceSnapshot.dueDate
        });
        emit InvoiceApproved(invoiceId, _validUntil, feeParams);
    }

    /// @notice Calculates the interest, protocol fee, admin fee, and spread for a given invoice approval over a specified number of days
    /// @param approval The invoice approval details
    /// @param daysOfInterest The number of days over which interest is calculated
    /// @return interest The calculated base interest amount (target yield portion)
    /// @return spreadAmount The calculated spread amount
    /// @return protocolFee The calculated protocol fee amount
    /// @return adminFee The calculated admin fee amount
    function calculateFees(InvoiceApproval memory approval, uint256 daysOfInterest, IInvoiceProviderAdapterV2.Invoice memory invoice) private pure returns (uint256 interest, uint256 spreadAmount, uint256 protocolFee, uint256 adminFee, uint256 kickbackAmount) {
        // Calculate the APR discount for the payment period
        // millibips used due to the small nature of the fees
        uint256 _targetYieldMbps = Math.mulDiv(uint256(approval.feeParams.targetYieldBps) * 1000, daysOfInterest, 365);
        uint256 spreadRateMbps = Math.mulDiv(uint256(approval.feeParams.spreadBps) * 1000, daysOfInterest, 365);
        
        // Calculate the admin fee rate
        uint256 adminFeeRateMbps = Math.mulDiv(uint256(approval.feeParams.adminFeeBps) * 1000, daysOfInterest, 365);

        uint256 protocolFeeRateMbps = Math.mulDiv(uint256(approval.feeParams.protocolFeeBps) * 1000, daysOfInterest, 365);
        
        // Calculate the total fee rate Mbps (base yield + spread + protocol fee + admin fee)
        uint256 totalFeeRateMbps = _targetYieldMbps + spreadRateMbps + adminFeeRateMbps + protocolFeeRateMbps;

        // cap kickback amount to the principal amount
        uint256 capKickbackAmount = approval.initialInvoiceValue > approval.fundedAmountNet ? approval.initialInvoiceValue - approval.fundedAmountNet : 0;
        
        // cap total fees to max available to distribute
        // invoice amount includes interest
        // Handle case where override amount might be higher than invoice amount
        uint256 availableFromInvoice = invoice.invoiceAmount - approval.initialPaidAmount;
        uint256 capTotalFees =
            availableFromInvoice > approval.fundedAmountNet
            ? availableFromInvoice - approval.fundedAmountNet
            : 0;

        uint256 minimumFees = capTotalFees > capKickbackAmount ? capTotalFees - capKickbackAmount : 0;

        // Calculate total fees on the principal amount only
        uint256 totalFees = Math.max(Math.min(capTotalFees, Math.mulDiv(approval.initialInvoiceValue, totalFeeRateMbps, 10_000_000)), minimumFees);
        
        adminFee = totalFeeRateMbps == 0 || totalFees == 0 ? 0 : Math.mulDiv(totalFees, adminFeeRateMbps, totalFeeRateMbps);
        interest = totalFeeRateMbps == 0 || totalFees == 0 ? 0 : Math.mulDiv(totalFees, _targetYieldMbps, totalFeeRateMbps);
        spreadAmount = totalFeeRateMbps == 0 || totalFees == 0 ? 0 : Math.mulDiv(totalFees, spreadRateMbps, totalFeeRateMbps);
        protocolFee = totalFees - adminFee - interest - spreadAmount;

        // Handle case where total fees might exceed available amount from invoice
        uint256 totalDueToCreditor =
            availableFromInvoice > totalFees
            ? availableFromInvoice - totalFees
            : 0;

        kickbackAmount = totalDueToCreditor > approval.fundedAmountNet ? totalDueToCreditor - approval.fundedAmountNet : 0;

        return (interest, spreadAmount, protocolFee, adminFee, kickbackAmount);
    }

    /// @notice Calculates the kickback amount for a given funded amount allowing early payment
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueSpreadAmount The true spread amount
    /// @return trueProtocolFee The true protocol fee amount
    /// @return trueAdminFee The true admin fee amount
    function calculateKickbackAmount(uint256 invoiceId) external view returns (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        return _calculateKickbackAmount(invoiceId, invoice);
    }

    /// @notice Internal optimized version of calculateKickbackAmount when invoice data is already available
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @param invoice The invoice data to avoid external call
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueSpreadAmount The true spread amount
    /// @return trueProtocolFee The true protocol fee amount
    /// @return trueAdminFee The true admin fee amount
    function _calculateKickbackAmount(uint256 invoiceId, IInvoiceProviderAdapterV2.Invoice memory invoice) internal view returns (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee) {
        InvoiceApproval memory approval = approvedInvoices[invoiceId];

        uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? Math.mulDiv(block.timestamp - approval.fundedTimestamp, 1, 1 days, Math.Rounding.Floor) : 0;
        
        uint256 daysOfInterest = daysSinceFunded = Math.max(daysSinceFunded, approval.feeParams.minDaysInterestApplied);

        (trueInterest, trueSpreadAmount, trueProtocolFee, trueAdminFee, kickbackAmount) = calculateFees(approval, daysOfInterest, invoice);

        return (kickbackAmount, trueInterest, trueSpreadAmount, trueProtocolFee, trueAdminFee);
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
            uint256 initialPaidAmount = approvedInvoices[invoiceId].initialPaidAmount;
            uint256 currentPaidAmount = invoiceProviderAdapter.getInvoiceDetails(invoiceId).paidAmount;
            int256 lossAmount = int256(approvedInvoices[invoiceId].fundedAmountNet) - int256(currentPaidAmount - initialPaidAmount) - int256(impairments[invoiceId].gainAmount);
            realizedGains -= lossAmount;
        }

        // Consider losses from impaired invoices in activeInvoices
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            uint256 currentPaidAmount = invoice.paidAmount;
            if (invoice.isImpaired) {
                uint256 initialPaidAmount = approvedInvoices[invoiceId].initialPaidAmount;
                int256 lossAmount = int256(approvedInvoices[invoiceId].fundedAmountNet) - int256(currentPaidAmount - initialPaidAmount);
                realizedGains -= lossAmount;
            }
        }

        return realizedGains;
    }

    /// @notice Calculates the capital account balance, including deposits, withdrawals, and realized gains/losses
    /// @return The calculated capital account balance
    function calculateCapitalAccount() public view returns (uint256) {
        int256 realizedGainLoss = calculateRealizedGainLoss();

        return _calculateCapitalAccountWithCache(realizedGainLoss);
    }

    /// @notice Memory-cached version of calculateCapitalAccount that calculates realized gain/loss once
    /// @param realizedGainLoss Pre-calculated realized gain/loss value
    /// @return The calculated capital account balance
    function _calculateCapitalAccountWithCache(int256 realizedGainLoss) internal view returns (uint256) {
        int256 depositsMinusWithdrawals = int256(totalDeposits) - int256(totalWithdrawals);
        int256 capitalAccount = depositsMinusWithdrawals + realizedGainLoss;

        return capitalAccount > 0 ? uint(capitalAccount) : 0;
    }

    /// @notice Calculates the current price per share of the fund, 
    /// @return The current price per share, scaled to the underlying asset's decimal places
    function pricePerShare() public view returns (uint256) {
        return previewRedeem(10**decimals());
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            return assets;
        }

        return assets.mulDiv(_totalSupply, calculateCapitalAccount(), rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            return shares;
        }

        return shares.mulDiv(calculateCapitalAccount(), _totalSupply, rounding);
    }

    /// @notice Calculates the total accrued profits from all active invoices
    /// @dev Iterates through all active invoices, calculates interest for each and sums the net accrued interest
    /// @return accruedProfits The total net accrued profits across all active invoices
    function calculateAccruedProfits() public view returns (uint256 accruedProfits) {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            
            if(!invoice.isImpaired) {
                (,uint256 trueInterest,,,) = _calculateKickbackAmount(invoiceId, invoice);
                accruedProfits += trueInterest;
            }
        }

        return accruedProfits;
    }

    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 sharesOutstanding = totalSupply();
        uint256 shares;

        if(sharesOutstanding == 0) {
            shares = assets;
        } else {
            // Memory-optimized: Calculate capital account and accrued profits with single pass through invoices
            (uint256 capitalAccount, , uint256 accruedProfits) = _calculateAllFinancialMetricsOptimized();
            shares = Math.mulDiv(assets, sharesOutstanding, (capitalAccount + accruedProfits), Math.Rounding.Floor);
        }

        return shares;
    }

    /// @notice Helper function to handle the logic of depositing assets in exchange for fund shares
    /// @param receiver The address to receive the fund shares
    /// @param assets The amount of assets to deposit
    /// @return The number of shares issued for the deposit
    function deposit(uint256 assets,address receiver) public override returns (uint256) {
        if (!depositPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        
        _reconcileActivePaidInvoices();
        _processRedemptionQueue();

        uint256 shares = super.deposit(assets, receiver);
        totalDeposits += assets;

        // it might look strange to call this twice, but I think it is the way to go.
        // the first processing of the queue is due to paid invoices. If we only call it once after the deposit, it is unfair to the depositor,
        // due to the accured interest that is paid by them leaking out to redemptioners.
        // This assures they get to keep the extra accrued interest value that they paid for when entering the pool, so to not enter at a loss.
        _processRedemptionQueue();
        
        return shares;
    }

    /// @notice Calculates the true fees and net funded amount for a given invoice and factorer's upfront bps, annualised
    /// @param invoiceId The ID of the invoice for which to calculate the fees
    /// @param factorerUpfrontBps The upfront bps specified by the factorer
    /// @return fundedAmountGross The gross amount to be funded to the factorer
    /// @return adminFee The target calculated admin fee
    /// @return targetInterest The calculated interest fee
    /// @return targetSpreadAmount The calculated spread amount
    /// @return targetProtocolFee The calculated protocol fee
    /// @return netFundedAmount The net amount that will be funded to the factorer after deducting fees
    function calculateTargetFees(uint256 invoiceId, uint16 factorerUpfrontBps) public view returns (uint256 fundedAmountGross, uint256 adminFee, uint256 targetInterest, uint256 targetSpreadAmount, uint256 targetProtocolFee, uint256 netFundedAmount) {
        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        if (!approval.approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approval.feeParams.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();

        fundedAmountGross = Math.mulDiv(approval.initialInvoiceValue, factorerUpfrontBps, 10000);

        uint256 daysUntilDue =  Math.mulDiv(approval.invoiceDueDate - block.timestamp, 1, 1 days, Math.Rounding.Floor);

        /// @dev minDaysInterestApplied is the minimum number of days the invoice can be funded for, set by the underwriter during approval
        daysUntilDue = Math.max(daysUntilDue, approval.feeParams.minDaysInterestApplied);

        (targetInterest, targetSpreadAmount, targetProtocolFee, adminFee, ) = calculateFees(approval, daysUntilDue, invoice);

        uint256 totalFees = adminFee + targetInterest + targetSpreadAmount + targetProtocolFee;
        netFundedAmount = fundedAmountGross > totalFees ? fundedAmountGross - totalFees : 0;

        return (fundedAmountGross, adminFee, targetInterest, targetSpreadAmount, targetProtocolFee, netFundedAmount);
    }

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @dev No checks needed for the creditor, as transferFrom will revert unless it gets executed by the nft owner (i.e. claim creditor)
    /// @param invoiceId The ID of the invoice to fund
    /// @param factorerUpfrontBps factorer specified upfront bps
    /// @param receiverAddress Address to receive the funds, if address(0) then funds go to msg.sender
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps, address receiverAddress) external returns(uint256) {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!redemptionQueue.isQueueEmpty()) revert RedemptionQueueNotEmpty();
        if (!approvedInvoices[invoiceId].approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approvedInvoices[invoiceId].feeParams.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approvedInvoices[invoiceId].validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapterV2.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoicesDetails.isCanceled) revert InvoiceCanceled();
        if (approvedInvoices[invoiceId].initialPaidAmount != invoicesDetails.paidAmount) revert InvoicePaidAmountChanged();
        if (approvedInvoices[invoiceId].creditor != invoicesDetails.creditor) revert InvoiceCreditorChanged();

        (uint256 fundedAmountGross,,,,,uint256 fundedAmountNet) = calculateTargetFees(invoiceId, factorerUpfrontBps);
        uint256 _totalAssets = totalAssets();
        // needs to be gross amount here, because the fees will be locked, and we need liquidity to lock these
        if(fundedAmountGross > _totalAssets) revert InsufficientFunds(_totalAssets, fundedAmountGross);

        // store values in approvedInvoices
        approvedInvoices[invoiceId].fundedAmountGross = fundedAmountGross;
        approvedInvoices[invoiceId].fundedAmountNet = fundedAmountNet;
        approvedInvoices[invoiceId].fundedTimestamp = block.timestamp;
        // update upfrontBps with what was passed in the arg by the factorer
        approvedInvoices[invoiceId].feeParams.upfrontBps = factorerUpfrontBps; 

        // Determine the actual receiver address - use msg.sender if receiverAddress is address(0)
        address actualReceiver = receiverAddress == address(0) ? msg.sender : receiverAddress;

        // Store the receiver address for future kickback payments
        approvedInvoices[invoiceId].receiverAddress = actualReceiver;

        // transfer net funded amount to caller to the actual receiver
        assetAddress.safeTransfer(actualReceiver, fundedAmountNet);

        // transfer invoice nft ownership to vault
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress(invoiceId);
        IERC721(invoiceContractAddress).transferFrom(msg.sender, address(this), invoiceId);

        originalCreditors[invoiceId] = msg.sender;
        activeInvoices.push(invoiceId);

        emit InvoiceFunded(invoiceId, fundedAmountNet, msg.sender, approvedInvoices[invoiceId].invoiceDueDate, factorerUpfrontBps);
        return fundedAmountNet;
    }

    /// @notice Provides a view of the pool's status, listing paid and impaired invoices, to be called by Gelato or alike
    /// @return paidInvoiceIds An array of paid invoice IDs
    /// @return paidInvoices An array of paid invoice data
    /// @return impairedInvoiceIds An array of impaired invoice IDs
    /// @return impairedInvoices An array of impaired invoice data
    function viewPoolStatus() public view returns (
        uint256[] memory paidInvoiceIds,
        IInvoiceProviderAdapterV2.Invoice[] memory paidInvoices,
        uint256[] memory impairedInvoiceIds, 
        IInvoiceProviderAdapterV2.Invoice[] memory impairedInvoices
    ) {
        uint256 activeCount = activeInvoices.length;
        uint256 impairedByFundCount = impairedByFundInvoicesIds.length;
        
        paidInvoiceIds = new uint256[](activeCount + impairedByFundCount);
        paidInvoices = new IInvoiceProviderAdapterV2.Invoice[](activeCount + impairedByFundCount);
        impairedInvoiceIds = new uint256[](activeCount);
        impairedInvoices = new IInvoiceProviderAdapterV2.Invoice[](activeCount);
        
        uint256 paidCount = 0;
        uint256 impairedCount = 0;

        // Check active invoices
        for (uint256 i = 0; i < activeCount; i++) {
            uint256 invoiceId = activeInvoices[i];

            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            if (invoice.isPaid) {
                paidInvoiceIds[paidCount] = invoiceId;
                paidInvoices[paidCount++] = invoice;
            } else if (invoice.isImpaired) {
                impairedInvoiceIds[impairedCount] = invoiceId;
                impairedInvoices[impairedCount++] = invoice;
            }
        }

        // Check impaired invoices by the fund
        for (uint256 i = 0; i < impairedByFundCount; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            
            if (invoice.isPaid) {
                paidInvoiceIds[paidCount] = invoiceId;
                paidInvoices[paidCount++] = invoice;
            }
        }

        // Overwrite the length of the arrays
        assembly {
            mstore(paidInvoiceIds, paidCount)
            mstore(paidInvoices, paidCount)
            mstore(impairedInvoiceIds, impairedCount)
            mstore(impairedInvoices, impairedCount)
        }

        return (paidInvoiceIds, paidInvoices, impairedInvoiceIds, impairedInvoices);
    }

    /// @notice Increments the profit, and fee balances for a given invoice
    /// @param invoiceId The ID of the invoice
    /// @param trueInterest The true interest amount for the invoice
    /// @param trueSpreadAmount The true spread amount for the invoice
    /// @param trueProtocolFee The true protocol fee amount for the invoice
    /// @param trueAdminFee The true admin fee amount for the invoice
    function incrementProfitAndFeeBalances(uint256 invoiceId, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee) private {
        // Add the admin fee to the balance
        adminFeeBalance += trueAdminFee;

        // store factoring gain (base yield only)
        paidInvoicesGain[invoiceId] = trueInterest;

        // store spread gain separately
        paidInvoicesSpreadGain[invoiceId] = trueSpreadAmount;
        spreadGainsBalance += trueSpreadAmount;

        // Update protocol fee balance
        protocolFeeBalance += trueProtocolFee;

        // Add the invoice ID to the paidInvoicesIds array
        paidInvoicesIds.push(invoiceId);
    }

    /// @notice Reconciles the list of active invoices with those that have been paid, updating the fund's records
    /// @dev This function should be called when viewPoolStatus returns some updates, to ensure accurate accounting
    function reconcileActivePaidInvoices() external {
        _reconcileActivePaidInvoices();
        _processRedemptionQueue();
    }

    function _reconcileActivePaidInvoices() internal {
        (uint256[] memory paidInvoiceIds, IInvoiceProviderAdapterV2.Invoice[] memory paidInvoices, , ) = viewPoolStatus();

        for (uint256 i = 0; i < paidInvoiceIds.length; i++) {
            uint256 invoiceId = paidInvoiceIds[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = paidInvoices[i];
            
            // calculate kickback amount adjusting for true interest, protocol and admin fees
            (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee) = _calculateKickbackAmount(invoiceId, invoice);
 
            incrementProfitAndFeeBalances(invoiceId, trueInterest, trueSpreadAmount, trueProtocolFee, trueAdminFee);   

            address receiverAddress = approvedInvoices[invoiceId].receiverAddress;
            
            if (kickbackAmount != 0) {
                assetAddress.safeTransfer(receiverAddress, kickbackAmount);
                emit InvoiceKickbackAmountSent(invoiceId, kickbackAmount, receiverAddress);
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
            emit InvoicePaid(invoiceId, trueInterest, trueSpreadAmount, trueProtocolFee, trueAdminFee, approval.fundedAmountNet, kickbackAmount, receiverAddress);
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

    function removePendingLoanOffer(uint256 loanOfferId) private {
        for (uint256 i = 0; i < pendingLoanOffersIds.length; i++) {
            if (pendingLoanOffersIds[i] == loanOfferId) {
                pendingLoanOffersIds[i] = pendingLoanOffersIds[pendingLoanOffersIds.length - 1];
                pendingLoanOffersIds.pop();
                break;
            }
        }
    }

    /// @notice Unfactors an invoice, returning the invoice NFT to the original creditor and refunding the funded amount
    /// @param invoiceId The ID of the invoice to unfactor
    function unfactorInvoice(uint256 invoiceId) external {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        
        if (invoice.isPaid) revert InvoiceAlreadyPaid();
        address originalCreditor = originalCreditors[invoiceId];
        if (originalCreditor != msg.sender) revert CallerNotOriginalCreditor();

        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        // Calculate the funded amount for the invoice
        uint256 fundedAmount = approval.fundedAmountNet;

        // Calculate the number of days since funding
         uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? Math.mulDiv(block.timestamp - approval.fundedTimestamp, 1, 1 days, Math.Rounding.Floor) : 0;
        (uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueProtocolFee, uint256 trueAdminFee, ) = calculateFees(approval, daysSinceFunded, invoice);
        // Need to subtract payments since funding start
        uint256 paymentSinceFunding = invoice.paidAmount - approval.initialPaidAmount;
        int256 totalRefundOrPaymentAmount = int256(fundedAmount + trueInterest + trueSpreadAmount + trueProtocolFee + trueAdminFee) - int256(paymentSinceFunding);

        // positive number means the original creditor owes us the amount
        if(totalRefundOrPaymentAmount > 0) {
            // Refund the funded amount to the fund from the original creditor
            assetAddress.safeTransferFrom(originalCreditor, address(this), uint256(totalRefundOrPaymentAmount));
        } else if (totalRefundOrPaymentAmount < 0) {
            // negative number means we owe them
            assetAddress.safeTransfer(originalCreditor, uint256(-totalRefundOrPaymentAmount));
        }

        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress(invoiceId);
        IERC721(invoiceContractAddress).transferFrom(address(this), originalCreditor, invoiceId);

        // Update the contract's state to reflect the unfactoring
        removeActivePaidInvoice(invoiceId);
        incrementProfitAndFeeBalances(invoiceId, trueInterest, trueSpreadAmount, trueProtocolFee, trueAdminFee);

        delete originalCreditors[invoiceId];

        _reconcileActivePaidInvoices();
        _processRedemptionQueue();

        emit InvoiceUnfactored(invoiceId, originalCreditor, totalRefundOrPaymentAmount, trueInterest, trueSpreadAmount, trueProtocolFee, trueAdminFee);
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

    /// @notice Calculates the total funded amount for all active invoices.
    /// @return The total funded amount for all active invoices
    function deployedCapitalForActiveInvoicesExcludingImpaired() public view returns (uint256) {
        uint256 deployedCapital = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            deployedCapital += (invoice.isImpaired) ? 0 : approvedInvoices[invoiceId].fundedAmountNet;
        }
        return deployedCapital;
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

    /// @notice Calculates the available assets in the fund net of fees and impair reserve
    /// @return The amount of assets available for withdrawal or new investments, excluding funds allocated to active invoices
    function totalAssets() public view override returns (uint256) {
        return _totalAssetsOptimized(calculateCapitalAccount());
    }
    
    /// @notice Calculates the total assets of the fund using pre-calculated capital account
    /// @param capitalAccount The capital account of the fund
    /// @return The total assets of the fund
    function _totalAssetsOptimized(uint256 capitalAccount) private view returns (uint256) {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            capitalAccount -= (invoice.isImpaired ? 0 : approvedInvoices[invoiceId].fundedAmountNet) + (approvedInvoices[invoiceId].fundedAmountGross - approvedInvoices[invoiceId].fundedAmountNet);
        }
        return capitalAccount;
    }

    /// @notice Memory-optimized version that calculates both capital account and total assets with single realized gain/loss calculation
    /// @return capitalAccount The calculated capital account balance
    /// @return totalAssetsAmount The total assets of the fund
    function _calculateCapitalAccountAndTotalAssets() internal view returns (uint256 capitalAccount, uint256 totalAssetsAmount) {
        // Calculate realized gain/loss once and reuse
        int256 realizedGainLoss = calculateRealizedGainLoss();
        capitalAccount = _calculateCapitalAccountWithCache(realizedGainLoss);
        totalAssetsAmount = _totalAssetsOptimized(capitalAccount);
    }

    /// @notice Memory-optimized version that fetches all active invoice details once and calculates multiple metrics
    /// @return realizedGainLoss The realized gain/loss value
    /// @return accruedProfits The accrued profits from active invoices
    /// @return deployedCapital The deployed capital excluding impaired invoices
    /// @return targetFees The sum of target fees for active invoices
    function _calculateInvoiceMetricsOptimized() internal view returns (
        int256 realizedGainLoss,
        uint256 accruedProfits, 
        uint256 deployedCapital,
        uint256 targetFees
    ) {
        // Calculate paid invoices gain first (doesn't require external calls)
        realizedGainLoss = 0;
        for (uint256 i = 0; i < paidInvoicesIds.length; i++) {
            uint256 invoiceId = paidInvoicesIds[i];
            realizedGainLoss += int256(paidInvoicesGain[invoiceId]);
        }

        // Handle impaired invoices by fund (requires external calls)
        for (uint256 i = 0; i < impairedByFundInvoicesIds.length; i++) {
            uint256 invoiceId = impairedByFundInvoicesIds[i];
            uint256 initialPaidAmount = approvedInvoices[invoiceId].initialPaidAmount;
            uint256 currentPaidAmount = invoiceProviderAdapter.getInvoiceDetails(invoiceId).paidAmount;
            int256 lossAmount = int256(approvedInvoices[invoiceId].fundedAmountNet) - int256(currentPaidAmount - initialPaidAmount) - int256(impairments[invoiceId].gainAmount);
            realizedGainLoss -= lossAmount;
        }

        // Process active invoices once - fetch all invoice details and calculate multiple metrics
        accruedProfits = 0;
        deployedCapital = 0;
        targetFees = 0;

        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            uint256 fundedAmountNet = approvedInvoices[invoiceId].fundedAmountNet;
            uint256 invoiceTargetFees = approvedInvoices[invoiceId].fundedAmountGross - fundedAmountNet;
            
            // Add to target fees
            targetFees += invoiceTargetFees;
            
            if (invoice.isImpaired) {
                // Calculate loss for realized gain/loss
                uint256 initialPaidAmount = approvedInvoices[invoiceId].initialPaidAmount;
                int256 lossAmount = int256(fundedAmountNet) - int256(invoice.paidAmount - initialPaidAmount);
                realizedGainLoss -= lossAmount;
                // Impaired invoices don't contribute to deployed capital or accrued profits
            } else {
                // Add to deployed capital
                deployedCapital += fundedAmountNet;
                // Calculate accrued profits
                (, uint256 trueInterest, , , ) = _calculateKickbackAmount(invoiceId, invoice);
                accruedProfits += trueInterest;
            }
        }
    }

    /// @notice Ultra-optimized function that calculates all key financial metrics with minimal external calls
    /// @return capitalAccount The calculated capital account balance
    /// @return totalAssetsAmount The total assets of the fund
    /// @return accruedProfits The accrued profits from active invoices
    function _calculateAllFinancialMetricsOptimized() internal view returns (
        uint256 capitalAccount,
        uint256 totalAssetsAmount,
        uint256 accruedProfits
    ) {
        // Get all invoice metrics with single pass through active invoices
        (int256 realizedGainLoss, uint256 _accruedProfits, uint256 deployedCapital, uint256 targetFees) = _calculateInvoiceMetricsOptimized();
        
        // Calculate capital account using cached realized gain/loss
        capitalAccount = _calculateCapitalAccountWithCache(realizedGainLoss);
        
        // Calculate total assets using pre-calculated components
        totalAssetsAmount = capitalAccount - deployedCapital - targetFees;
        
        accruedProfits = _accruedProfits;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() public view returns (uint256) {
        return _maxRedeemOptimized(calculateCapitalAccount(), totalAssets());
    }
    
    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @param _capitalAccount The capital account of the fund
    /// @param _totalAssets The total assets of the fund
    /// @return The maximum number of shares that can be redeemed
    function _maxRedeemOptimized(uint256 _capitalAccount, uint256 _totalAssets) private view returns (uint256) {
        if (_capitalAccount == 0) {
            return 0;
        }

        uint256 maxWithdrawableShares = convertToShares(_totalAssets);
        return maxWithdrawableShares;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @param _owner The owner of the shares being redeemed
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem(address _owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(_owner), maxRedeem());
    }

    /// @notice Calculates the maximum amount of assets that can be withdrawn
    /// @param _owner The owner of the assets to be withdrawn
    /// @return The maximum number of assets that can be withdrawn
    function maxWithdraw(address _owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(_owner), totalAssets());
    }

    /// @notice Helper function to handle the logic of withdrawing assets in exchange for fund shares
    /// @param receiver The address to receive the assets
    /// @param _owner The address who owns the shares to redeem
    /// @param assets The amount of assets to withdraw
    /// @return The number of shares redeemed
    function withdraw(uint256 assets, address receiver, address _owner) public override returns (uint256) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);

        _reconcileActivePaidInvoices();
        _processRedemptionQueue();
        
        if (!redemptionQueue.isQueueEmpty()) revert RedemptionQueueNotEmpty();
 
        uint256 shares = super.withdraw(assets, receiver, _owner);

        totalWithdrawals += assets;
        return shares;
    }

    /// @notice Helper function to handle the logic of redeeming shares in exchange for assets
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the assets
    /// @param _owner The owner of the shares being redeemed
    /// @return The number of shares redeemed
    function redeem(uint256 shares, address receiver, address _owner) public override returns (uint256) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);

        _reconcileActivePaidInvoices();
        _processRedemptionQueue();

        if (!redemptionQueue.isQueueEmpty()) revert RedemptionQueueNotEmpty();
        
        uint256 assets = super.redeem(shares, receiver, _owner);

        totalWithdrawals += assets;

        return assets;
    }

    /// @notice Sets the grace period in days for determining if an invoice is impaired
    /// @param _days The number of days for the grace period
    /// @dev This function can only be called by the contract owner
    function setGracePeriodDays(uint256 _days) external onlyOwner {
        gracePeriodDays = _days;
        emit GracePeriodDaysChanged(_days);
    }

    /// @notice Sets the duration for which invoice approvals are valid
    /// @param _duration The new duration in seconds
    /// @dev This function can only be called by the contract owner
    function setApprovalDuration(uint256 _duration) external onlyOwner {
        approvalDuration = _duration;
        emit ApprovalDurationChanged(_duration);
    }

    /// @notice Sets a new underwriter for the contract
    /// @param _newUnderwriter The address of the new underwriter
    function setUnderwriter(address _newUnderwriter) external onlyOwner {
        if (_newUnderwriter == address(0)) revert InvalidAddress();
        address oldUnderwriter = underwriter;
        underwriter = _newUnderwriter;
        emit UnderwriterChanged(oldUnderwriter, _newUnderwriter);
    }

    /// @notice Allows the Bulla DAO to withdraw accumulated protocol fees.
    function withdrawProtocolFees() external onlyBullaDao {
        uint256 feeAmount = protocolFeeBalance;
        if (feeAmount == 0) revert NoFeesToWithdraw();
        protocolFeeBalance = 0;
        assetAddress.safeTransfer(bullaDao, feeAmount);
        emit ProtocolFeesWithdrawn(bullaDao, feeAmount);
    }

    /// @notice Allows the Pool Owner to withdraw accumulated admin fees and spread gains.
    function withdrawAdminFeesAndSpreadGains() external onlyOwner {
        uint256 adminFeeAmount = adminFeeBalance;
        uint256 spreadAmount = spreadGainsBalance;
        uint256 totalAmount = adminFeeAmount + spreadAmount;
        
        if (totalAmount == 0) revert NoFeesToWithdraw();
        
        adminFeeBalance = 0;
        spreadGainsBalance = 0;
        
        assetAddress.safeTransfer(msg.sender, totalAmount);
        emit AdminFeesWithdrawn(msg.sender, adminFeeAmount);
        emit SpreadGainsWithdrawn(msg.sender, spreadAmount);
    }

    /// @notice Updates the Bulla DAO address
    /// @param _newBullaDao The new address for the Bulla DAO
    function setBullaDaoAddress(address _newBullaDao) external onlyBullaDao {
        if (_newBullaDao == address(0)) revert InvalidAddress();
        address oldBullaDao = bullaDao;
        bullaDao = _newBullaDao;
        emit BullaDaoAddressChanged(oldBullaDao, _newBullaDao);
    }

    /// @notice Updates the protocol fee in basis points (bps)
    /// @param _newProtocolFeeBps The new protocol fee in basis points
    function setProtocolFeeBps(uint16 _newProtocolFeeBps) external onlyBullaDao {
        if (_newProtocolFeeBps > 10000) revert InvalidPercentage();
        uint16 oldProtocolFeeBps = protocolFeeBps;
        protocolFeeBps = _newProtocolFeeBps;
        emit ProtocolFeeBpsChanged(oldProtocolFeeBps, _newProtocolFeeBps);
    }

    /// @notice Sets the admin fee in basis points
    /// @param _newAdminFeeBps The new admin fee in basis points
    function setAdminFeeBps(uint16 _newAdminFeeBps) external onlyOwner {
        if (_newAdminFeeBps > 10000) revert InvalidPercentage();
        uint16 oldAdminFeeBps = adminFeeBps;
        adminFeeBps = _newAdminFeeBps;
        emit AdminFeeBpsChanged(oldAdminFeeBps, _newAdminFeeBps);
    }

    function mint(uint256, address) public pure override returns (uint256){
        revert FunctionNotSupported();
    }

    /// @notice Updates the deposit permissions contract
    /// @param _newDepositPermissionsAddress The new deposit permissions contract address
    function setDepositPermissions(address _newDepositPermissionsAddress) external onlyOwner {
        depositPermissions = Permissions(_newDepositPermissionsAddress);
        emit DepositPermissionsChanged(_newDepositPermissionsAddress);
    }

    /// @notice Updates the redeem permissions contract
    /// @param _newRedeemPermissionsAddress The new redeem permissions contract address
    function setRedeemPermissions(address _newRedeemPermissionsAddress) external onlyOwner {
        redeemPermissions = Permissions(_newRedeemPermissionsAddress);
        emit RedeemPermissionsChanged(_newRedeemPermissionsAddress);
    }

    /// @notice Updates the factoring permissions contract
    /// @param _newFactoringPermissionsAddress The address of the new factoring permissions contract
    function setFactoringPermissions(address _newFactoringPermissionsAddress) external onlyOwner {
        factoringPermissions = Permissions(_newFactoringPermissionsAddress);
        emit FactoringPermissionsChanged(_newFactoringPermissionsAddress);
    }

    /// @notice Sets the impair reserve amount
    /// @param _impairReserve The new impair reserve amount
    function setImpairReserve(uint256 _impairReserve) external onlyOwner {
        if (_impairReserve < impairReserve) revert ImpairReserveMustBeGreater();
        uint256 amountToAdd = _impairReserve - impairReserve;
        assetAddress.safeTransferFrom(msg.sender, address(this), amountToAdd);
        impairReserve = _impairReserve;
        emit ImpairReserveChanged(_impairReserve);
    }

    /// @notice Sets the target yield in basis points
    /// @param _targetYieldBps The new target yield in basis points
    function setTargetYield(uint16 _targetYieldBps) external onlyOwner {
        if (_targetYieldBps > 10000) revert InvalidPercentage();
        targetYieldBps = _targetYieldBps;
        emit TargetYieldChanged(_targetYieldBps);
    }

    /// @notice Retrieves the fund information
    /// @return FundInfo The fund information
    function getFundInfo() external view returns (FundInfo memory) {
        uint256 fundBalance = totalAssets();
        uint256 deployedCapital = deployedCapitalForActiveInvoicesExcludingImpaired();
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 price = pricePerShare();
        uint256 tokensAvailableForRedemption = maxRedeem();

        return FundInfo({
            name: poolName,
            creationTimestamp: creationTimestamp,
            fundBalance: fundBalance,
            deployedCapital: deployedCapital,
            capitalAccount: capitalAccount,
            price: price,
            tokensAvailableForRedemption: tokensAvailableForRedemption,
            adminFeeBps: adminFeeBps,
            impairReserve: impairReserve,
            targetYieldBps: targetYieldBps
        });
    }

    /// @notice Impairs an invoice, using the impairment reserve to cover the loss
    /// @param invoiceId The ID of the invoice to impair
    function impairInvoice(uint256 invoiceId) external onlyOwner {
        if (impairReserve == 0) revert ImpairReserveNotSet();
        
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (!invoice.isImpaired) revert InvoiceNotImpaired();

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

        // Get the target contract and selector from the adapter, then call directly
        // This preserves msg.sender == BullaFactoring for the underlying contract
        (address target, bytes4 selector) = invoiceProviderAdapter.getImpairTarget(invoiceId);
        
        if (target != address(0)) {
            bytes memory callData = abi.encodeWithSelector(selector, invoiceId);
            (bool success, ) = target.call(callData);
            require(success, "Impair call failed");
        }

        emit InvoiceImpaired(invoiceId, fundedAmount, impairAmount);
    }

    modifier onlyBullaDao() {
        if (msg.sender != bullaDao) revert CallerNotBullaDao();
        _;
    }

    // Redemption Queue Functions

    /// @notice Attempt to redeem shares, queuing excess if insufficient liquidity
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param _owner The owner of the shares being redeemed
    /// @return redeemedAssets The amount of assets actually redeemed
    /// @return queuedShares The amount of shares queued for future redemption
    function redeemAndOrQueue(uint256 shares, address receiver, address _owner) external returns (uint256 redeemedAssets, uint256 queuedShares) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);

        _reconcileActivePaidInvoices();
        _processRedemptionQueue();

        uint256 maxRedeemableShares = maxRedeem(_owner);
        uint256 sharesToRedeem = Math.min(shares, maxRedeemableShares);
        
        if (sharesToRedeem > 0) {
            redeemedAssets = super.redeem(sharesToRedeem, receiver, _owner);
            totalWithdrawals += redeemedAssets;
        }

        queuedShares = shares - sharesToRedeem;
        if (queuedShares > 0) {
            // Queue the remaining shares for future redemption
            redemptionQueue.queueRedemption(_owner, receiver, queuedShares, 0);
        }
    }

    /// @notice Attempt to withdraw assets, queuing excess if insufficient liquidity
    /// @param assets The amount of assets to withdraw
    /// @param receiver The address to receive the withdrawn assets
    /// @param _owner The owner of the shares being redeemed
    /// @return redeemedShares The amount of shares actually redeemed
    /// @return queuedAssets The amount of assets queued for future withdrawal
    function withdrawAndOrQueue(uint256 assets, address receiver, address _owner) external returns (uint256 redeemedShares, uint256 queuedAssets) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);

        _reconcileActivePaidInvoices();
        _processRedemptionQueue();

        uint256 maxWithdrawableAssets = maxWithdraw(_owner);
        uint256 assetsToWithdraw = Math.min(assets, maxWithdrawableAssets);
        
        if (assetsToWithdraw > 0) {
            redeemedShares = super.withdraw(assetsToWithdraw, receiver, _owner);
            totalWithdrawals += assetsToWithdraw;
        }

        queuedAssets = assets - assetsToWithdraw;
        if (queuedAssets > 0) {
            // Queue the remaining assets for future withdrawal
            redemptionQueue.queueRedemption(_owner, receiver, 0, queuedAssets);
        }
    }

    function processRedemptionQueue() external onlyOwner {
        _processRedemptionQueue();
    }

    /// @notice Process queued redemptions when liquidity becomes available
    function _processRedemptionQueue() private {
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        // Memory-optimized: Calculate capital account and total assets with single realized gain/loss calculation
        (uint256 _capitalAccount, uint256 _totalAssets) = _calculateCapitalAccountAndTotalAssets();
        uint256 maxRedeemableShares = _maxRedeemOptimized(_capitalAccount, _totalAssets);
        
        while (redemption.owner != address(0) && _totalAssets > 0) {
            uint256 amountProcessed = 0; // this is shares or assets depending on the investor
            
            if (redemption.shares > 0) {
                // This is a share-based redemption
                uint256 sharesToRedeem = Math.min(redemption.shares, maxRedeemableShares);
                
                if (sharesToRedeem > 0) {
                    // Pre-validation: Check if owner has enough shares (bypass allowance check)
                    uint256 ownerBalance = balanceOf(redemption.owner);
                    
                    if (ownerBalance >= sharesToRedeem) {
                        // Owner has sufficient funds - process redemption bypassing allowance
                        uint256 assets = previewRedeem(sharesToRedeem);
                        _withdraw(redemption.owner, redemption.receiver, redemption.owner, assets, sharesToRedeem);
                        totalWithdrawals += assets;
                        amountProcessed = sharesToRedeem;
                        _totalAssets -= assets;
                        maxRedeemableShares -= sharesToRedeem;
                    } else {
                        // Owner doesn't have sufficient funds - remove from queue
                        amountProcessed = redemption.shares;
                    }
                } else {
                    // No liquidity available - stop processing to maintain FIFO order
                    break;
                }
            } else if (redemption.assets > 0) {
                // This is an asset-based withdrawal
                uint256 maxWithdrawableAssets = maxWithdraw(redemption.owner);
                uint256 assetsToWithdraw = Math.min(redemption.assets, maxWithdrawableAssets);
                
                if (assetsToWithdraw > 0) {
                    // Pre-validation: Check if owner has enough shares for withdrawal (bypass allowance check)
                    uint256 sharesToBurn = previewWithdraw(assetsToWithdraw);
                    uint256 ownerBalance = balanceOf(redemption.owner);
                    
                    if (ownerBalance >= sharesToBurn) {
                        // Owner has sufficient funds - process withdrawal bypassing allowance
                        _withdraw(redemption.owner, redemption.receiver, redemption.owner, assetsToWithdraw, sharesToBurn);
                        totalWithdrawals += assetsToWithdraw;
                        amountProcessed = assetsToWithdraw;
                        _totalAssets -= assetsToWithdraw;
                        maxRedeemableShares -= sharesToBurn;
                    } else {
                        // Owner doesn't have sufficient funds - remove from queue
                        amountProcessed = redemption.assets;
                    }
                } else {
                    // No liquidity available - stop processing to maintain FIFO order
                    break;
                }
            }
            
            if (amountProcessed > 0) {
                // Remove the processed redemption from the queue
                redemption = redemptionQueue.removeAmountFromFirstOwner(amountProcessed);
            } else {
                // Can't process this redemption, stop processing
                break;
            }
        }
    }

    /// @notice Get the redemption queue contract
    /// @return The redemption queue contract interface
    function getRedemptionQueue() external view returns (IRedemptionQueue) {
        return redemptionQueue;
    }

    /// @notice Set the redemption queue contract
    /// @param _redemptionQueue The new redemption queue contract address
    function setRedemptionQueue(address _redemptionQueue) external onlyOwner {
        if (_redemptionQueue == address(0)) revert InvalidAddress();

        address oldQueue = address(redemptionQueue);
        redemptionQueue = IRedemptionQueue(_redemptionQueue);
        emit RedemptionQueueChanged(oldQueue, _redemptionQueue);
    }
}