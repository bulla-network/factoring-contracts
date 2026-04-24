// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import "./interfaces/IInvoiceProviderAdapter.sol";
import {IBullaFactoringV2_2} from "./interfaces/IBullaFactoring.sol";
import "./interfaces/IRedemptionQueue.sol";
import "./Permissions.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import "./RedemptionQueue.sol";
import "./libraries/FeeCalculations.sol";
import "./libraries/ApprovalPacking.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Bulla Factoring Fund
/// @author @solidoracle
/// @notice Bulla Factoring Fund is a ERC4626 compatible fund that allows for the factoring of invoices
contract BullaFactoringV2_2 is IBullaFactoringV2_2, ERC20, ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

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
    uint256 private totalDeposits; 
    uint256 private totalWithdrawals;
    /// @notice Address of the underwriter, trusted to approve invoices
    address public underwriter;
    /// @notice Timestamp of the fund's creation
    uint256 public creationTimestamp;
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
    uint256 public paidInvoicesGain = 0;

    /// Accumulated losses from impaired invoices (the funded capital that was lost)
    uint256 public impairmentLosses = 0;

    /// Mapping from invoice ID to original creditor's address
    mapping(uint256 => address) public originalCreditors;

    /// Mapping from invoice ID to invoice approval details
    mapping(uint256 => InvoiceApproval) public approvedInvoices;
    /// @notice The duration of invoice approval before it expires
    uint256 public approvalDuration = 1 hours;

    /// Set to hold the IDs of all active invoices (O(1) add/remove/contains)
    EnumerableSet.UintSet private _activeInvoices;

    // ============ Aggregate State Tracking Variables ============
    /// @notice Total per-second interest rate across all active invoices in RAY units (sum of all perSecondInterestRate values)
    /// @dev RAY = 1e27 for high-precision per-second interest accrual (Aave V3 style)
    uint256 private totalPerSecondInterestRateRay = 0;
    
    /// @notice Timestamp when accrued profits were last checkpointed
    uint256 private lastCheckpointTimestamp;
    
    /// @notice Accrued profits at the last checkpoint in RAY units (1e27)
    /// @dev Stored in RAY for precision, converted to token decimals when accessed via calculateAccruedProfits()
    uint256 private accruedProfitsAtCheckpointRay = 0;
    
    /// @notice Total capital at risk plus withheld fees (sum of fundedAmountGross for all active invoices, where fundedAmountGross includes protocol fee)
    uint256 private capitalAtRiskPlusWithheldFees = 0;

    /// @notice Total withheld fees (sum of withheld fees for all active invoices)
    uint256 private withheldFees = 0;

    // ============ Insurance State Variables ============
    address public insurer;
    uint16 public insuranceFeeBps;
    uint16 public impairmentGrossGainBps;
    uint16 public recoveryProfitRatioBps;
    uint256 public insuranceBalance;
    mapping(uint256 => ImpairmentInfo) public impairmentInfo;
    uint256[] public impairedInvoices;

    /// Errors
    error CallerNotUnderwriter();
    error FunctionNotSupported();
    error UnauthorizedDeposit(address caller);
    error UnauthorizedWithdrawal(address caller);
    error UnauthorizedRedeem(address caller);
    error UnauthorizedFactoring(address caller);
    error InvoiceAlreadyPaid();
    error CallerNotOriginalCreditor();
    error CallerNotBullaDao();
    error NoFeesToWithdraw();
    error InvalidAddress();
    error InvoiceCannotBePaid();
    error InvoiceTokenMismatch();
    error InvoiceAlreadyFunded();
    error InsufficientFunds(uint256 available, uint256 required);
    error RedemptionQueueNotEmpty();
    error InvoiceNotActive();
    error InvoiceSetPaidCallbackFailed();
    error InvoiceNotApproved();
    error ApprovalExpired();
    error InvoiceCanceled();
    error InvoicePaidAmountChanged();
    error InvalidPercentage();
    error InvoiceCreditorChanged();
    error InvoiceNotPaid();
    error InvoiceNotImpaired();
    error CallerNotInsurer();
    error InvalidReceiverAddressIndex();
    error InvoiceAlreadyImpaired();
    error InvoiceImpairFailed();
    error ImpairmentGrossGainBpsMustBePositive();
    error UnauthorizedReceiverAddress(address receiver);
    error UnauthorizedTransfer(address account);

    modifier onlyInsurer() {
        if (msg.sender != insurer) revert CallerNotInsurer();
        _;
    }

    /// @param _asset underlying supported stablecoin asset for deposit 
    /// @param _invoiceProviderAdapter adapter for invoice provider
    /// @param _underwriter address of the underwriter
    constructor(
        IERC20 _asset,
        IInvoiceProviderAdapterV2 _invoiceProviderAdapter,
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
        string memory _tokenSymbol,
        address _insurer,
        uint16 _insuranceFeeBps,
        uint16 _impairmentGrossGainBps,
        uint16 _recoveryProfitRatioBps
    ) ERC20(_tokenName, _tokenSymbol) ERC4626(_asset) Ownable(_msgSender()) {
        if (_protocolFeeBps < 0 || _protocolFeeBps > 10000) revert InvalidPercentage();
        if (_adminFeeBps < 0 || _adminFeeBps > 10000) revert InvalidPercentage();
        if (_insuranceFeeBps > 10000) revert InvalidPercentage();
        if (_impairmentGrossGainBps == 0) revert ImpairmentGrossGainBpsMustBePositive();
        if (_impairmentGrossGainBps > 10000) revert InvalidPercentage();
        if (_recoveryProfitRatioBps > 10000) revert InvalidPercentage();

        assetAddress = _asset;
        invoiceProviderAdapter = _invoiceProviderAdapter;
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
        insurer = _insurer;
        insuranceFeeBps = _insuranceFeeBps;
        impairmentGrossGainBps = _impairmentGrossGainBps;
        recoveryProfitRatioBps = _recoveryProfitRatioBps;
        redemptionQueue = new RedemptionQueue(msg.sender, address(this));

        // Initialize aggregate state tracking
        lastCheckpointTimestamp = block.timestamp;
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

    /// @notice Restricts token transfers to addresses approved by deposit permissions
    /// @dev Minting (from == address(0)) and burning (to == address(0)) are exempt as they
    ///      are already gated by deposit() and redeem()/withdraw() permission checks respectively
    function _update(address from, address to, uint256 value) internal override(ERC20) {
        if (from != address(0) && to != address(0)) {
            if (!depositPermissions.isAllowed(from)) revert UnauthorizedTransfer(from);
            if (!depositPermissions.isAllowed(to)) revert UnauthorizedTransfer(to);
        }
        super._update(from, to, value);
    }

    /// @notice Checkpoints the aggregate accrued profits state
    /// @dev Updates accruedProfitsAtCheckpointRay based on time passed and current totalPerSecondInterestRateRay
    /// @dev This should be called before any operation that modifies totalPerSecondInterestRateRay
    function _checkpointAccruedProfits() internal {
        if (block.timestamp > lastCheckpointTimestamp) {
            uint256 secondsSinceCheckpoint = block.timestamp - lastCheckpointTimestamp;
            
            // Accumulate interest in RAY units (no conversion yet - stays in RAY for precision)
            // perSecondRateRay * seconds = accumulated interest in RAY
            accruedProfitsAtCheckpointRay += totalPerSecondInterestRateRay * secondsSinceCheckpoint;
            
            // Update checkpoint timestamp
            lastCheckpointTimestamp = block.timestamp;
        }
    }

    /// @notice Adds an invoice to the aggregate state tracking
    /// @param perSecondInterestRateRay The per-second interest rate for this invoice in RAY units
    function _addInvoiceToAggregate(uint256 perSecondInterestRateRay) internal {
        // Checkpoint before modifying aggregate state
        _checkpointAccruedProfits();
        
        // Add to aggregate (RAY units)
        totalPerSecondInterestRateRay += perSecondInterestRateRay;
    }

    /// @notice Approves multiple invoices for funding in a single transaction, can only be called by the underwriter
    /// @param params Array of ApproveInvoiceParams structs
    function approveInvoices(ApproveInvoiceParams[] calldata params) external {
        if (msg.sender != underwriter) revert CallerNotUnderwriter();
        for (uint256 i = 0; i < params.length; i++) {
            _approveInvoice(params[i]);
        }
    }

    /// @notice Internal function to approve a single invoice for funding
    /// @param params The approval parameters
    function _approveInvoice(ApproveInvoiceParams calldata params) internal {
        if (params.upfrontBps <= 0 || params.upfrontBps > 10000) revert InvalidPercentage();
        uint256 _validUntil = block.timestamp + approvalDuration;
        invoiceProviderAdapter.initializeInvoice(params.invoiceId);
        IInvoiceProviderAdapterV2.Invoice memory invoiceSnapshot = invoiceProviderAdapter.getInvoiceDetails(params.invoiceId);
        if (invoiceSnapshot.isPaid) revert InvoiceAlreadyPaid();
        if (invoiceSnapshot.invoiceAmount - invoiceSnapshot.paidAmount == 0) revert InvoiceCannotBePaid();
        // if invoice already got approved and funded (creditor/owner of invoice is this contract), do not override storage
        // we assume that invoices are always from the bulla protocol and the creditor is always the NFT owner
        if (invoiceSnapshot.creditor == address(this)) revert InvoiceAlreadyFunded();
        // check claim token is equal to pool token
        if (invoiceSnapshot.tokenAddress != address(assetAddress)) revert InvoiceTokenMismatch();

        FeeParams memory feeParams = FeeParams({
            targetYieldBps: params.targetYieldBps,
            spreadBps: params.spreadBps,
            upfrontBps: params.upfrontBps,
            protocolFeeBps: protocolFeeBps,
            adminFeeBps: adminFeeBps
        });

        uint256 _initialInvoiceValue = params.initialInvoiceValueOverride != 0 ? params.initialInvoiceValueOverride : invoiceSnapshot.invoiceAmount - invoiceSnapshot.paidAmount;

        approvedInvoices[params.invoiceId] = InvoiceApproval({
            approved: true,
            validUntil: _validUntil,
            creditor: invoiceSnapshot.creditor,
            fundedTimestamp: 0,
            feeParams: feeParams,
            fundedAmountGross: 0,
            fundedAmountNet: 0,
            initialInvoiceValue: _initialInvoiceValue,
            initialPaidAmount: invoiceSnapshot.paidAmount,
            receiverAddress: address(0),
            invoiceDueDate: invoiceSnapshot.dueDate,
            impairmentDate: invoiceSnapshot.dueDate + invoiceSnapshot.impairmentGracePeriod,
            protocolFeeAndInsurancePremium: 0,
            perSecondInterestRateRay: FeeCalculations.calculatePerSecondInterestRateRay(_initialInvoiceValue, params.targetYieldBps)
        });
        emit InvoiceApproved(params.invoiceId, _validUntil, feeParams);
    }


    /// @notice Calculates the kickback amount for a given funded amount allowing early payment
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueSpreadAmount The true spread amount
    /// @return trueAdminFee The true admin fee amount
    function calculateKickbackAmount(uint256 invoiceId) external view returns (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        IBullaFactoringV2_2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        return FeeCalculations.calculateKickbackAmount(approval, invoice);
    }

    /// @notice Calculates the capital account balance, including deposits, withdrawals, and realized gains/losses
    /// @return The calculated capital account balance
    function calculateCapitalAccount() public view returns (uint256) {
        int256 capitalAccount = int256(totalDeposits) + int256(paidInvoicesGain) - int256(totalWithdrawals) - int256(impairmentLosses);

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

    /// @notice Calculates the accrued profits of active invoices
    /// @dev This function uses accrued profits at last checkpoint + pending seconds since checkpoint * total per-second interest rate (all in RAY)
    /// @return The accrued profits in token decimals (converted from RAY)
    function calculateAccruedProfits() public view returns (uint256) {
        // Calculate seconds since last checkpoint
        uint256 secondsSinceCheckpoint = block.timestamp - lastCheckpointTimestamp;
        
        // O(1) calculation: checkpoint value (RAY) + accumulated interest since checkpoint (RAY)
        uint256 totalAccruedProfitsRay = accruedProfitsAtCheckpointRay + (totalPerSecondInterestRateRay * secondsSinceCheckpoint);
        
        // Convert from RAY to token decimals
        return totalAccruedProfitsRay / FeeCalculations.RAY;
    }

    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 sharesOutstanding = totalSupply();
        uint256 shares;

        if(sharesOutstanding == 0) {
            shares = assets;
        } else {
            // Calculate capital account and accrued profits
            uint256 capitalAccount = calculateCapitalAccount();
            uint256 accruedProfits = calculateAccruedProfits();
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
        
        uint256 shares = super.deposit(assets, receiver);
        totalDeposits += assets;

        // Process redemption queue after deposit due to new liquidity
        processRedemptionQueue();

        return shares;
    }

    /// @notice Calculates the true fees and net funded amount for a given invoice and factorer's upfront bps, annualised
    /// @param invoiceId The ID of the invoice for which to calculate the fees
    /// @param factorerUpfrontBps The upfront bps specified by the factorer
    /// @return fundedAmountGross The gross amount to be funded to the factorer
    /// @return adminFee The target calculated admin fee
    /// @return targetInterest The calculated interest fee
    /// @return targetSpreadAmount The calculated spread amount
    /// @return protocolFee The protocol fee amount
    /// @return insurancePremium The insurance premium amount
    /// @return netFundedAmount The net amount that will be funded to the factorer after deducting fees
    function calculateTargetFees(uint256 invoiceId, uint16 factorerUpfrontBps) public view returns (uint256 fundedAmountGross, uint256 adminFee, uint256 targetInterest, uint256 targetSpreadAmount, uint256 protocolFee, uint256 insurancePremium, uint256 netFundedAmount) {
        IBullaFactoringV2_2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        if (!approval.approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approval.feeParams.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();

        return FeeCalculations.calculateTargetFees(approval, invoice, factorerUpfrontBps, protocolFeeBps, insuranceFeeBps);
    }

    /// @notice Registers the reconcile callback with the invoice provider
    /// @param invoiceId The ID of the invoice to register callback for
    function _registerInvoiceCallback(uint256 invoiceId) internal {
        (address target, bytes4 selector) = invoiceProviderAdapter.getSetPaidInvoiceTarget(invoiceId);
        (bool success, ) = target.call(abi.encodeWithSelector(selector, invoiceId, address(this), this.reconcileSingleInvoice.selector));
        if (!success) revert InvoiceSetPaidCallbackFailed();
    }

    /// @notice Funds multiple invoices in a single transaction
    /// @dev No checks needed for the creditor, as transferFrom will revert unless it gets executed by the nft owner (i.e. claim creditor)
    /// @param params Array of FundInvoiceParams structs
    /// @param receiverAddresses Array of receiver addresses; each invoice references one by index. address(0) means msg.sender. Reverts if index is out of bounds.
    /// @return fundedAmounts Array of net funded amounts for each invoice
    function fundInvoices(FundInvoiceParams[] calldata params, address[] calldata receiverAddresses) external returns(uint256[] memory fundedAmounts) {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!redemptionQueue.isQueueEmpty()) revert RedemptionQueueNotEmpty();

        _checkpointAccruedProfits();

        fundedAmounts = new uint256[](params.length);
        uint256[] memory receiverAmounts = new uint256[](receiverAddresses.length);

        // Accumulate per-invoice results
        uint256[5] memory totals; // [protocolFee, insurancePremium, fundedGross, withheldFees, perSecondRate]

        for (uint256 i = 0; i < params.length; i++) {
            uint256 receiverIdx = params[i].receiverAddressIndex;
            (
                uint256 fundedAmountGross,
                uint256 fundedAmountNet,
                uint256 pFee,
                uint256 iPremium,
                uint256 perSecondRate
            ) = _fundInvoice(params[i], receiverAddresses);

            fundedAmounts[i] = fundedAmountNet;
            totals[0] += pFee;
            totals[1] += iPremium;
            totals[2] += fundedAmountGross;
            totals[3] += fundedAmountGross - fundedAmountNet;
            totals[4] += perSecondRate;
            receiverAmounts[receiverIdx] += fundedAmountNet;
        }

        // Single liquidity check for the entire batch
        {
            uint256 _totalAssets = totalAssets();
            if (totals[2] > _totalAssets) revert InsufficientFunds(_totalAssets, totals[2]);
        }

        // Batch state updates (single SSTORE per variable)
        protocolFeeBalance += totals[0];
        insuranceBalance += totals[1];
        capitalAtRiskPlusWithheldFees += totals[2];
        withheldFees += totals[3];
        totalPerSecondInterestRateRay += totals[4];

        // Batch transfers by receiver (address(0) slots go to msg.sender)
        uint256 msgSenderTotal = 0;
        for (uint256 i = 0; i < receiverAddresses.length; i++) {
            if (receiverAmounts[i] > 0) {
                if (receiverAddresses[i] == address(0)) {
                    msgSenderTotal += receiverAmounts[i];
                } else {
                    assetAddress.safeTransfer(receiverAddresses[i], receiverAmounts[i]);
                }
            }
        }
        if (msgSenderTotal > 0) {
            assetAddress.safeTransfer(msg.sender, msgSenderTotal);
        }
        return fundedAmounts;
    }

    /// @notice Internal function to process a single invoice within a batch — validates, calculates fees,
    ///         updates per-invoice storage, transfers NFT, but does NOT transfer funds or update aggregate state.
    /// @return fundedAmountGross, fundedAmountNet, protocolFee, insurancePremium, perSecondInterestRateRay
    function _fundInvoice(
        FundInvoiceParams calldata params,
        address[] calldata receiverAddresses
    ) internal returns (uint256, uint256, uint256, uint256, uint256) {
        IBullaFactoringV2_2.InvoiceApproval memory approval = approvedInvoices[params.invoiceId];

        if (!approval.approved) revert InvoiceNotApproved();
        if (params.factorerUpfrontBps > approval.feeParams.upfrontBps || params.factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approval.validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapterV2.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(params.invoiceId);
        if (invoicesDetails.isCanceled) revert InvoiceCanceled();
        if (invoicesDetails.isPaid) revert InvoiceAlreadyPaid();
        if (approval.initialPaidAmount != invoicesDetails.paidAmount) revert InvoicePaidAmountChanged();
        if (approval.creditor != invoicesDetails.creditor) revert InvoiceCreditorChanged();

        (uint256 fundedAmountGross, , , , uint256 protocolFee, uint256 insurancePremium, uint256 fundedAmountNet) = FeeCalculations.calculateTargetFees(approval, invoicesDetails, params.factorerUpfrontBps, protocolFeeBps, insuranceFeeBps);

        // Update per-invoice approval struct
        approval.fundedAmountGross = fundedAmountGross;
        approval.fundedAmountNet = fundedAmountNet;
        approval.fundedTimestamp = block.timestamp;
        approval.feeParams.upfrontBps = params.factorerUpfrontBps;
        approval.protocolFeeAndInsurancePremium = ApprovalPacking.packFees(protocolFee, insurancePremium);

        if (params.receiverAddressIndex >= receiverAddresses.length) revert InvalidReceiverAddressIndex();
        address actualReceiver = receiverAddresses[params.receiverAddressIndex] == address(0) ? msg.sender : receiverAddresses[params.receiverAddressIndex];
        if (receiverAddresses[params.receiverAddressIndex] != address(0) && !factoringPermissions.isAllowed(actualReceiver)) {
            revert UnauthorizedReceiverAddress(actualReceiver);
        }

        approval.receiverAddress = actualReceiver;
        approvedInvoices[params.invoiceId] = approval;

        // Per-invoice operations: NFT transfer, tracking, callback
        IERC721(invoiceProviderAdapter.getInvoiceContractAddress(params.invoiceId)).transferFrom(msg.sender, address(this), params.invoiceId);
        originalCreditors[params.invoiceId] = msg.sender;
        _activeInvoices.add(params.invoiceId);
        _registerInvoiceCallback(params.invoiceId);

        emit InvoiceFunded(params.invoiceId, fundedAmountNet, msg.sender, approval.invoiceDueDate, params.factorerUpfrontBps, protocolFee, actualReceiver);

        return (fundedAmountGross, fundedAmountNet, protocolFee, insurancePremium, approval.perSecondInterestRateRay);
    }

    function getActiveInvoices() external view returns (uint256[] memory) {
        return _activeInvoices.values();
    }

    function getActiveInvoicesCount() external view returns (uint256) {
        return _activeInvoices.length();
    }

    function getActiveInvoiceAt(uint256 index) external view returns (uint256) {
        return _activeInvoices.at(index);
    }

    /// @notice View pool status with pagination to handle large numbers of active invoices
    /// @dev To be called by Gelato or similar automation services. Limit is capped at 25000 invoices to prevent gas issues.
    /// @param offset The starting index in the activeInvoices array
    /// @param limit The maximum number of invoices to check (capped at 25000)
    /// @return impairedInvoiceIds Array of invoice IDs that are impaired in this page
    /// @return hasMore Whether there are more active invoices beyond this page
    function viewPoolStatus(uint256 offset, uint256 limit) external view returns (uint256[] memory impairedInvoiceIds, bool hasMore) {
        uint256 activeCount = _activeInvoices.length();
        
        // Cap the limit at 25000 to prevent gas issues
        if (limit > 25000) {
            limit = 25000;
        }
        
        // Calculate the end index for this page
        uint256 endIndex = Math.min(offset + limit, activeCount);
        
        // Check if there are more invoices beyond this page
        hasMore = endIndex < activeCount;
        
        // Allocate array for worst case (all invoices in range are impaired)
        uint256 rangeSize = endIndex > offset ? endIndex - offset : 0;
        impairedInvoiceIds = new uint256[](rangeSize);
        
        uint256 impairedCount = 0;

        // Check active invoices in the specified range
        for (uint256 i = offset; i < endIndex; i++) {
            uint256 invoiceId = _activeInvoices.at(i);

            if (_isInvoiceImpaired(invoiceId)) {
                impairedInvoiceIds[impairedCount++] = invoiceId;
            }
        }

        // Overwrite the length of the array
        assembly {
            mstore(impairedInvoiceIds, impairedCount)
        }
    }

    /// @notice Increments the profit, fee, and protocol fee balances for a given invoice
    /// @param trueInterest The true interest amount for the invoice
    /// @param trueSpreadAmount The true spread amount for the invoice
    /// @param trueAdminFee The true admin fee amount for the invoice
    function incrementProfitAndFeeBalances(uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee) private {
        // Add the admin fee to the balance
        adminFeeBalance += trueAdminFee + trueSpreadAmount;

        // store factoring gain (base yield only)
        paidInvoicesGain += trueInterest;
    }

    function reconcileSingleInvoice(uint256 invoiceId) external {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (!invoice.isPaid) revert InvoiceNotPaid();

        ImpairmentInfo memory _impairment = impairmentInfo[invoiceId];

        if (_impairment.isImpaired) {
            // recoveredAmount is the amount paid since impairment, not the full paidAmount
            uint256 recoveredAmount = invoice.paidAmount - _impairment.paidAmountAtImpairment;

            // Insurance gets back purchasePrice first, then excess is split
            uint256 excess = recoveredAmount > _impairment.purchasePrice ? recoveredAmount - _impairment.purchasePrice : 0;
            uint256 investorShare = Math.mulDiv(excess, recoveryProfitRatioBps, 10000);
            uint256 insuranceShare = recoveredAmount - investorShare;

            insuranceBalance += insuranceShare;
            // investorShare is realised profit (interest) above insurance purchase price
            paidInvoicesGain += investorShare;

            // Reverse the net principal loss now that the invoice has been recovered.
            impairmentLosses -= _impairment.principalLoss;

            emit InsuranceRecovered(invoiceId, insuranceShare);

            for (uint256 i = 0; i < impairedInvoices.length; i++) {
                if (impairedInvoices[i] == invoiceId) {
                    impairedInvoices[i] = impairedInvoices[impairedInvoices.length - 1];
                    impairedInvoices.pop();
                    break;
                }
            }

            processRedemptionQueue();
            emit ImpairedInvoiceReconciled(invoiceId, recoveredAmount, insuranceShare, investorShare);
        } else {
            removeActivePaidInvoice(invoiceId);

            IBullaFactoringV2_2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
            (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee) = FeeCalculations.calculateKickbackAmount(approval, invoice);

            incrementProfitAndFeeBalances(trueInterest, trueSpreadAmount, trueAdminFee);

            address receiverAddress = approval.receiverAddress;

            if (kickbackAmount != 0) {
                assetAddress.safeTransfer(receiverAddress, kickbackAmount);
                emit InvoiceKickbackAmountSent(invoiceId, kickbackAmount, receiverAddress);
            }

            processRedemptionQueue();

            emit InvoicePaid(invoiceId, trueInterest, trueSpreadAmount, trueAdminFee, approval.fundedAmountNet, kickbackAmount, receiverAddress);
        }
    }


    /// @notice Internal helper to calculate unfactor amounts
    /// @param invoiceId The ID of the invoice
    /// @return totalRefundOrPaymentAmount The total amount to be refunded (negative) or paid (positive)
    /// @return trueInterest The interest accrued
    /// @return trueSpreadAmount The spread amount accrued
    /// @return trueAdminFee The admin fee accrued
    function _calculateUnfactorAmounts(uint256 invoiceId) internal view returns (
        int256 totalRefundOrPaymentAmount,
        uint256 trueInterest,
        uint256 trueSpreadAmount,
        uint256 trueAdminFee
    ) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        
        if (invoice.isPaid) revert InvoiceAlreadyPaid();

        IBullaFactoringV2_2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        uint256 paymentSinceFunding = invoice.paidAmount - approval.initialPaidAmount;
        
        // Calculate fees and amounts
        uint256 secondsSinceFunded = (block.timestamp > approval.fundedTimestamp) ? (block.timestamp - approval.fundedTimestamp) : 0;
        (trueInterest, trueSpreadAmount, trueAdminFee, ) = FeeCalculations.calculateFees(approval, secondsSinceFunded, invoice);
        totalRefundOrPaymentAmount = int256(approval.fundedAmountNet + trueInterest + trueSpreadAmount + trueAdminFee + ApprovalPacking.protocolFee(approval)) - int256(paymentSinceFunding);
    }

    /// @notice Preview the refund or payment amount for unfactoring an invoice
    /// @param invoiceId The ID of the invoice to preview
    /// @return totalRefundOrPaymentAmount The total amount to be refunded (negative) or paid (positive)
    function previewUnfactor(uint256 invoiceId) external view returns (int256 totalRefundOrPaymentAmount) {
        (totalRefundOrPaymentAmount, , , ) = _calculateUnfactorAmounts(invoiceId);
    }

    /// @notice Unfactors an invoice, returning the invoice NFT to the caller
    /// @dev Can be called by the original creditor anytime or by pool owner after impairment or if canceled
    /// @param invoiceId The ID of the invoice to unfactor
    function unfactorInvoice(uint256 invoiceId) external {
        (
            int256 totalRefundOrPaymentAmount,
            uint256 trueInterest,
            uint256 trueSpreadAmount,
            uint256 trueAdminFee
        ) = _calculateUnfactorAmounts(invoiceId);
        
        address originalCreditor = originalCreditors[invoiceId];
        bool isPoolOwnerUnfactoring = msg.sender == owner();

        if (isPoolOwnerUnfactoring) {
            // Pool owner can unfactor impaired or canceled invoices
            IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            if (!_isInvoiceImpaired(invoiceId) && !invoice.isCanceled) revert InvoiceNotImpaired();
        } else {
            // Original creditor can unfactor anytime
            if (originalCreditor != msg.sender) revert CallerNotOriginalCreditor();
        }

        // Handle payment/kickback between original creditor (or pool owner) and pool
        if(totalRefundOrPaymentAmount > 0) {
            // Original creditor (or pool owner) owes the pool
            assetAddress.safeTransferFrom(msg.sender, address(this), uint256(totalRefundOrPaymentAmount));
        } else if (totalRefundOrPaymentAmount < 0) {
            // Pool owes original creditor a kickback
            assetAddress.safeTransfer(originalCreditor, uint256(-totalRefundOrPaymentAmount));
        }

        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress(invoiceId);
        IERC721(invoiceContractAddress).transferFrom(address(this), msg.sender, invoiceId);

        removeActivePaidInvoice(invoiceId);
        incrementProfitAndFeeBalances(trueInterest, trueSpreadAmount, trueAdminFee);
        
        delete originalCreditors[invoiceId];

        // Process redemption queue after unfactoring due to capital returning to pool
        processRedemptionQueue();

        emit InvoiceUnfactored(invoiceId, originalCreditor, totalRefundOrPaymentAmount, trueInterest, trueSpreadAmount, trueAdminFee, isPoolOwnerUnfactoring);
    }

    /// @notice Removes an invoice from the list of active invoices once it has been paid
    /// @param invoiceId The ID of the invoice to remove
    function removeActivePaidInvoice(uint256 invoiceId) private {
        if (!_activeInvoices.remove(invoiceId)) revert InvoiceNotActive();

        uint256 perSecondRateRay = approvedInvoices[invoiceId].perSecondInterestRateRay;

        if (perSecondRateRay > 0) {
            // First, checkpoint to accumulate all interest up to this moment
            _checkpointAccruedProfits();

            // Calculate this invoice's total accrued interest since it was funded (in RAY units)
            uint256 secondsSinceFunding = block.timestamp - approvedInvoices[invoiceId].fundedTimestamp;
            uint256 invoiceAccruedInterestRay = perSecondRateRay * secondsSinceFunding;

            // Remove this invoice's accrued interest from the checkpoint (both in RAY)
            accruedProfitsAtCheckpointRay -= invoiceAccruedInterestRay;

            // Remove this invoice's per-second rate from future calculations (RAY units)
            totalPerSecondInterestRateRay -= perSecondRateRay;
        }
        // fundedAmountGross now includes protocol fee
        uint256 atRiskPlusWithheldFees = approvedInvoices[invoiceId].fundedAmountGross;

        // Remove from capital at risk plus withheld fees
        capitalAtRiskPlusWithheldFees -= atRiskPlusWithheldFees;

        // Remove from withheld fees
        withheldFees -= atRiskPlusWithheldFees - approvedInvoices[invoiceId].fundedAmountNet;
    }

    /// @notice Calculates the available assets in the fund net of fees
    /// @dev Uses O(1) aggregate capital at risk tracking instead of iterating through invoices
    /// @return The amount of assets available for withdrawal or new investments, excluding funds allocated to active invoices
    function totalAssets() public view override returns (uint256) {
        return calculateCapitalAccount() - capitalAtRiskPlusWithheldFees;
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
        if (adminFeeBalance == 0) revert NoFeesToWithdraw();
        uint256 _adminFeeBalance = adminFeeBalance;
        
        adminFeeBalance = 0;
        
        assetAddress.safeTransfer(msg.sender, _adminFeeBalance);
        emit AdminFeesWithdrawn(msg.sender, _adminFeeBalance);
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


    /// @notice Sets the target yield in basis points
    /// @param _targetYieldBps The new target yield in basis points
    function setTargetYield(uint16 _targetYieldBps) external onlyOwner {
        if (_targetYieldBps > 10000) revert InvalidPercentage();
        targetYieldBps = _targetYieldBps;
        emit TargetYieldChanged(_targetYieldBps);
    }

    function setInsurer(address _newInsurer) external onlyOwner {
        address oldInsurer = insurer;
        insurer = _newInsurer;
        emit InsurerChanged(oldInsurer, _newInsurer);
    }

    function setInsuranceParams(uint16 _insuranceFeeBps, uint16 _impairmentGrossGainBps, uint16 _recoveryProfitRatioBps) external onlyOwner {
        if (_insuranceFeeBps > 10000) revert InvalidPercentage();
        if (_impairmentGrossGainBps == 0) revert ImpairmentGrossGainBpsMustBePositive();
        if (_impairmentGrossGainBps > 10000) revert InvalidPercentage();
        if (_recoveryProfitRatioBps > 10000) revert InvalidPercentage();
        insuranceFeeBps = _insuranceFeeBps;
        impairmentGrossGainBps = _impairmentGrossGainBps;
        recoveryProfitRatioBps = _recoveryProfitRatioBps;
        emit InsuranceParamsChanged(_insuranceFeeBps, _impairmentGrossGainBps, _recoveryProfitRatioBps);
    }

    function withdrawInsuranceBalance() external onlyInsurer {
        uint256 amount = insuranceBalance;
        insuranceBalance = 0;
        assetAddress.safeTransfer(insurer, amount);
        emit InsuranceWithdrawn(insurer, amount);
    }

    function previewImpair(uint256 invoiceId) public view returns (
        uint256 outstandingBalance,
        uint256 impairmentGrossGain,
        uint256 adminFeeOwed,
        uint256 impairmentNetGain,
        uint256 outOfPocketCost,
        uint256 currentPaidAmount,
        uint256 spreadOwed
    ) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        IBullaFactoringV2_2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        currentPaidAmount = invoice.paidAmount;
        outstandingBalance = invoice.invoiceAmount - invoice.paidAmount;
        impairmentGrossGain = Math.mulDiv(outstandingBalance, impairmentGrossGainBps, 10000);
        uint256 secondsSinceFunded = (block.timestamp > approval.fundedTimestamp) ? (block.timestamp - approval.fundedTimestamp) : 0;
        (, spreadOwed, adminFeeOwed, ) = FeeCalculations.calculateFees(approval, secondsSinceFunded, invoice);
        uint256 ownerFeesOwed = adminFeeOwed + spreadOwed;
        impairmentNetGain = impairmentGrossGain > ownerFeesOwed ? impairmentGrossGain - ownerFeesOwed : 0;
        outOfPocketCost = impairmentGrossGain > insuranceBalance ? impairmentGrossGain - insuranceBalance : 0;
    }

    function impairInvoice(uint256 invoiceId) external onlyInsurer {
        if (impairmentInfo[invoiceId].isImpaired) revert InvoiceAlreadyImpaired();
        (uint256 outstandingBalance, uint256 _impairmentGrossGain, uint256 adminFeeOwed, uint256 _impairmentNetGain, uint256 _outOfPocketCost, uint256 currentPaidAmount, uint256 spreadOwed) = previewImpair(invoiceId);
        removeActivePaidInvoice(invoiceId);
        (address target, bytes4 selector) = invoiceProviderAdapter.getImpairTarget(invoiceId);
        (bool success, ) = target.call(abi.encodeWithSelector(selector, invoiceId));
        if (!success) revert InvoiceImpairFailed();
        insuranceBalance -= (_impairmentGrossGain - _outOfPocketCost);
        if (_outOfPocketCost > 0) {
            assetAddress.safeTransferFrom(insurer, address(this), _outOfPocketCost);
        }
        IBullaFactoringV2_2.InvoiceApproval memory _approval = approvedInvoices[invoiceId];
        uint256 poolOwnedWithheld = _approval.fundedAmountGross - _approval.fundedAmountNet - ApprovalPacking.protocolFee(_approval) - ApprovalPacking.insurancePremium(_approval);
        // Combine insurance payout and withheld fees as the total gross LP credit,
        // then subtract accrued fees from that combined pool.
        uint256 totalFeesOwed = adminFeeOwed + spreadOwed;
        uint256 grossLPCredit = _impairmentGrossGain + poolOwnedWithheld;
        uint256 feesCharged = totalFeesOwed > grossLPCredit ? grossLPCredit : totalFeesOwed;
        adminFeeBalance += feesCharged;
        uint256 lpCredit = grossLPCredit - feesCharged;
        // Principal loss = fundedAmountNet - lpCredit - paymentsSinceFunding.
        // Only payments AFTER funding count as recovery (initialPaidAmount predates the pool).
        // paidInvoicesGain is not touched — it tracks only realised interest.
        uint256 paymentsSinceFunding = currentPaidAmount - _approval.initialPaidAmount;
        uint256 credited = lpCredit + paymentsSinceFunding;
        uint256 _principalLoss = _approval.fundedAmountNet > credited
            ? _approval.fundedAmountNet - credited
            : 0;
        impairmentLosses += _principalLoss;
        impairmentInfo[invoiceId] = ImpairmentInfo({
            isImpaired: true,
            purchasePrice: _impairmentGrossGain,
            paidAmountAtImpairment: currentPaidAmount,
            principalLoss: _principalLoss
        });
        impairedInvoices.push(invoiceId);
        processRedemptionQueue();
        emit InvoiceImpaired(invoiceId, outstandingBalance, _impairmentGrossGain, _impairmentNetGain);
    }

    function getFundInfo() external view returns (FundInfo memory) {
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 fundBalance = capitalAccount - capitalAtRiskPlusWithheldFees;
        uint256 deployedCapital = capitalAtRiskPlusWithheldFees - withheldFees;
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
            targetYieldBps: targetYieldBps
        });
    }


    modifier onlyBullaDao() {
        if (msg.sender != bullaDao) revert CallerNotBullaDao();
        _;
    }

    /// @notice Helper function to check if an invoice is impaired based on approved invoice data
    /// @param invoiceId The ID of the invoice to check
    /// @return true if the invoice is past its impairment date, false otherwise
    function _isInvoiceImpaired(uint256 invoiceId) private view returns (bool) {
        uint256 impairmentDate = approvedInvoices[invoiceId].impairmentDate;
        return impairmentDate != 0 && block.timestamp > impairmentDate;
    }

    // Redemption Queue Functions

    /// @notice Redeem shares, queuing excess if insufficient liquidity
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param _owner The owner of the shares being redeemed
    /// @return The amount of assets redeemed
    function redeem(uint256 shares, address receiver, address _owner) public override returns (uint256) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedRedeem(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedRedeem(_owner);

        // Cap total shares to owner's balance to prevent queueing more than they have
        uint256 cappedShares = Math.min(balanceOf(_owner), shares);

        uint256 sharesToRedeem = redemptionQueue.isQueueEmpty() ? Math.min(cappedShares, maxRedeem()) : 0;
        uint256 redeemedAssets = 0;
        
        if (sharesToRedeem > 0) {
            redeemedAssets = super.redeem(sharesToRedeem, receiver, _owner);
            totalWithdrawals += redeemedAssets;
        }

        uint256 queuedShares = cappedShares - sharesToRedeem;
        if (queuedShares > 0) {
            // Consume allowance for queued shares (just like a normal redemption would)
            if (_msgSender() != _owner) {
                _spendAllowance(_owner, _msgSender(), queuedShares);
            }
            // Queue the remaining shares for future redemption
            // The RedemptionQueued event is emitted by the redemptionQueue.queueRedemption call
            redemptionQueue.queueRedemption(_owner, receiver, queuedShares, 0);
        }
        
        return redeemedAssets;
    }

    /// @notice Withdraw assets, queuing excess if insufficient liquidity
    /// @param assets The amount of assets to withdraw
    /// @param receiver The address to receive the withdrawn assets
    /// @param _owner The owner of the shares being redeemed
    /// @return The amount of shares redeemed
    function withdraw(uint256 assets, address receiver, address _owner) public override returns (uint256) {
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedWithdrawal(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedWithdrawal(_owner);
        
        // Cap total assets to what owner's shares can cover to prevent queueing more than they have
        uint256 maxOwnerAssets = previewRedeem(balanceOf(_owner));
        uint256 cappedAssets = assets > maxOwnerAssets ? maxOwnerAssets : assets;
        
        uint256 assetsToWithdraw = redemptionQueue.isQueueEmpty() ? Math.min(cappedAssets, maxWithdraw(_owner)) : 0;
        uint256 redeemedShares = 0;
        
        if (assetsToWithdraw > 0) {
            redeemedShares = super.withdraw(assetsToWithdraw, receiver, _owner);
            totalWithdrawals += assetsToWithdraw;
        }

        uint256 queuedAssets = cappedAssets - assetsToWithdraw;
        if (queuedAssets > 0) {
            // Consume allowance for queued assets (just like a normal withdrawal would)
            if (_msgSender() != _owner) {
                uint256 sharesToSpend = previewWithdraw(queuedAssets);
                _spendAllowance(_owner, _msgSender(), sharesToSpend);
            }
            // Queue the remaining assets for future withdrawal
            // The RedemptionQueued event is emitted by the redemptionQueue.queueRedemption call
            redemptionQueue.queueRedemption(_owner, receiver, 0, queuedAssets);
        }
        
        return redeemedShares;
    }

    /// @notice Process queued redemptions when liquidity becomes available
    function processRedemptionQueue() public {
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
        if (redemption.owner == address(0)) return;

        // Memory-optimized: Calculate capital account once and derive total assets
        uint256 _capitalAccount = calculateCapitalAccount();
        uint256 _totalAssets = _capitalAccount - capitalAtRiskPlusWithheldFees;
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
                uint256 assetsToWithdraw = Math.min(redemption.assets, _totalAssets); // == 0 if canceled or not enough liquidity. Cancellations should no longer exist since queue compacts on cancellation
                
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