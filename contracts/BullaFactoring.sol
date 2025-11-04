// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import "./interfaces/IInvoiceProviderAdapter.sol";
import {IBullaFactoringV2} from "./interfaces/IBullaFactoring.sol";
import "./interfaces/IRedemptionQueue.sol";
import "./Permissions.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IBullaFrendLendV2, LoanRequestParams} from "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {InterestConfig} from "@bulla/contracts-v2/src/libraries/CompoundInterestLib.sol";
import "./RedemptionQueue.sol";
import "./libraries/FeeCalculations.sol";

/// @title Bulla Factoring Fund
/// @author @solidoracle
/// @notice Bulla Factoring Fund is a ERC4626 compatible fund that allows for the factoring of invoices
contract BullaFactoringV2_1 is IBullaFactoringV2, ERC20, ERC4626, Ownable {
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
    uint256 private totalDeposits; 
    uint256 private totalWithdrawals;
    /// @notice Address of the bulla frendlend contract
    IBullaFrendLendV2 public bullaFrendLend;
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

    /// Mapping from invoice ID to original creditor's address
    mapping(uint256 => address) public originalCreditors;

    /// Mapping from invoice ID to invoice approval details
    mapping(uint256 => InvoiceApproval) public approvedInvoices;
    /// @notice The duration of invoice approval before it expires
    uint256 public approvalDuration = 1 hours;

    /// Array to hold the IDs of all active invoices
    uint256[] public activeInvoices;

    /// Mapping from loan offer ID to pending loan offer details
    mapping(uint256 => PendingLoanOfferInfo) public pendingLoanOffersByLoanOfferId;

    /// Array to track IDs of pending loan offers
    uint256[] public pendingLoanOffersIds;

    // ============ Aggregate State Tracking Variables ============
    /// @notice Total daily interest rate across all active invoices (sum of all dailyInterestRate values)
    uint256 private totalDailyInterestRate = 0;
    
    /// @notice Timestamp when accrued profits were last checkpointed
    uint256 private lastCheckpointTimestamp;
    
    /// @notice Accrued profits at the last checkpoint
    uint256 private accruedProfitsAtCheckpoint = 0;
    
    /// @notice Total capital at risk plus withheld fees (sum of fundedAmountGross + protocolFee for all active invoices)
    uint256 private capitalAtRiskPlusWithheldFees = 0;

    /// @notice Total withheld fees (sum of withheld fees for all active invoices)
    uint256 private withheldFees = 0;

    /// Errors
    error CallerNotUnderwriter();
    error FunctionNotSupported();
    error UnauthorizedDeposit(address caller);
    error UnauthorizedFactoring(address caller);
    error InvoiceAlreadyPaid();
    error CallerNotOriginalCreditor();
    error CallerNotBullaFrendLend();
    error CallerNotBullaDao();
    error NoFeesToWithdraw();
    error InvalidAddress();
    error InvoiceCannotBePaid();
    error InvoiceTokenMismatch();
    error InvoiceAlreadyFunded();
    error LoanOfferNotExists();
    error LoanOfferAlreadyAccepted();
    error InsufficientFunds(uint256 available, uint256 required);
    error RedemptionQueueNotEmpty();
    error CallerNotInvoiceContract();
    error InvoiceNotActive();
    error InvoiceSetPaidCallbackFailed();
    error InvoiceNotApproved();
    error ApprovalExpired();
    error InvoiceCanceled();
    error InvoicePaidAmountChanged();
    error InvalidPercentage();
    error InvoiceCreditorChanged();
    error InvoiceNotPaid();
    
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
        if (_protocolFeeBps < 0 || _protocolFeeBps > 10000) revert InvalidPercentage();
        if (_adminFeeBps < 0 || _adminFeeBps > 10000) revert InvalidPercentage();

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
        
        // Initialize aggregate state tracking
        lastCheckpointTimestamp = block.timestamp;
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

    /// @notice Checkpoints the aggregate accrued profits state
    /// @dev Updates accruedProfitsAtCheckpoint based on time passed and current totalDailyInterestRate
    /// @dev This should be called before any operation that modifies totalDailyInterestRate
    function _checkpointAccruedProfits() internal {
        if (block.timestamp > lastCheckpointTimestamp) {
            uint256 daysSinceCheckpoint = (block.timestamp - lastCheckpointTimestamp) / 1 days;
            
            // Accumulate interest for the time period since last checkpoint
            accruedProfitsAtCheckpoint += totalDailyInterestRate * daysSinceCheckpoint;
            
            // Update checkpoint timestamp
            lastCheckpointTimestamp = block.timestamp;
        }
    }

    /// @notice Adds an invoice to the aggregate state tracking
    /// @param dailyInterestRate The daily interest rate for this invoice
    function _addInvoiceToAggregate(uint256 dailyInterestRate) internal {
        // Checkpoint before modifying aggregate state
        _checkpointAccruedProfits();
        
        // Add to aggregate
        totalDailyInterestRate += dailyInterestRate;
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

        uint256 invoiceDueDate = block.timestamp + pendingLoanOffer.termLength;

        approvedInvoices[loanId] = InvoiceApproval({
            approved: true,
            validUntil: pendingLoanOffer.offeredAt,
            fundedTimestamp: block.timestamp,
            feeParams: pendingLoanOffer.feeParams,
            fundedAmountGross: pendingLoanOffer.principalAmount,
            fundedAmountNet: pendingLoanOffer.principalAmount,
            initialInvoiceValue: pendingLoanOffer.principalAmount,
            initialPaidAmount: 0,
            invoiceDueDate: invoiceDueDate,
            impairmentDate: invoiceDueDate + gracePeriodDays * 1 days,
            receiverAddress: address(this),
            creditor: address(this),
            protocolFee: 0,
            dailyInterestRate: Math.mulDiv(
                pendingLoanOffer.principalAmount,
                pendingLoanOffer.feeParams.targetYieldBps,
                3_650_000
            )
        });

        originalCreditors[loanId] = address(this);
        activeInvoices.push(loanId);
        
        // Add loan to aggregate state tracking
        _addInvoiceToAggregate(approvedInvoices[loanId].dailyInterestRate);
        
        // Add to capital at risk (principalAmount + protocolFee which is 0)
        capitalAtRiskPlusWithheldFees += pendingLoanOffer.principalAmount;
        
        invoiceProviderAdapter.initializeInvoice(loanId);
        _registerInvoiceCallback(loanId);
        
        emit InvoiceFunded(loanId, pendingLoanOffer.principalAmount, address(this), block.timestamp + pendingLoanOffer.termLength, pendingLoanOffer.feeParams.upfrontBps, 0);
    }

    /// @notice Approves an invoice for funding, can only be called by the underwriter
    /// @param invoiceId The ID of the invoice to approve
    /// @param _targetYieldBps The target yield in basis points
    /// @param _spreadBps The spread in basis points to add on top of target yield
    /// @param _upfrontBps The maximum upfront percentage the factorer can request
    /// @param _initialInvoiceValueOverride The initial invoice value to override the invoice amount. For example in cases of loans or bonds.
    function approveInvoice(uint256 invoiceId, uint16 _targetYieldBps, uint16 _spreadBps, uint16 _upfrontBps, uint256 _initialInvoiceValueOverride) external {
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
        if (invoiceSnapshot.tokenAddress != address(assetAddress)) revert InvoiceTokenMismatch();

        FeeParams memory feeParams = FeeParams({
            targetYieldBps: _targetYieldBps,
            spreadBps: _spreadBps,
            upfrontBps: _upfrontBps,
            protocolFeeBps: protocolFeeBps,
            adminFeeBps: adminFeeBps
        });

        uint256 _initialInvoiceValue = _initialInvoiceValueOverride != 0 ? _initialInvoiceValueOverride : invoiceSnapshot.invoiceAmount - invoiceSnapshot.paidAmount;
        
        approvedInvoices[invoiceId] = InvoiceApproval({
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
            protocolFee: 0,
            dailyInterestRate: Math.mulDiv(_initialInvoiceValue, _targetYieldBps, 3_650_000)
        });
        emit InvoiceApproved(invoiceId, _validUntil, feeParams);
    }


    /// @notice Calculates the kickback amount for a given funded amount allowing early payment
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @return kickbackAmount The calculated kickback amount
    /// @return trueInterest The true interest amount
    /// @return trueSpreadAmount The true spread amount
    /// @return trueAdminFee The true admin fee amount
    function calculateKickbackAmount(uint256 invoiceId) external view returns (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee) {
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        IBullaFactoringV2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        return FeeCalculations.calculateKickbackAmount(approval, invoice);
    }

    /// @notice Calculates the capital account balance, including deposits, withdrawals, and realized gains/losses
    /// @return The calculated capital account balance
    function calculateCapitalAccount() public view returns (uint256) {
        int256 capitalAccount = int256(totalDeposits) + int256(paidInvoicesGain) - int256(totalWithdrawals);

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
    /// @dev This function uses accrued profits at last checkpoint + pending days since checkpoint * total daily interest rate
    /// @return The accrued profits
    function calculateAccruedProfits() public view returns (uint256) {
        // Calculate days since last checkpoint
        uint256 daysSinceCheckpoint = (block.timestamp - lastCheckpointTimestamp) / 1 days;
        
        // O(1) calculation: checkpoint value + accumulated interest since checkpoint
        return accruedProfitsAtCheckpoint + (totalDailyInterestRate * daysSinceCheckpoint);
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
    /// @return netFundedAmount The net amount that will be funded to the factorer after deducting fees
    function calculateTargetFees(uint256 invoiceId, uint16 factorerUpfrontBps) public view returns (uint256 fundedAmountGross, uint256 adminFee, uint256 targetInterest, uint256 targetSpreadAmount, uint256 protocolFee, uint256 netFundedAmount) {
        IBullaFactoringV2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        IInvoiceProviderAdapterV2.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        if (!approval.approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approval.feeParams.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();

        return FeeCalculations.calculateTargetFees(approval, invoice, factorerUpfrontBps, protocolFeeBps);
    }

    /// @notice Registers the reconcile callback with the invoice provider
    /// @param invoiceId The ID of the invoice to register callback for
    function _registerInvoiceCallback(uint256 invoiceId) internal {
        (address target, bytes4 selector) = invoiceProviderAdapter.getSetPaidInvoiceTarget(invoiceId);
        (bool success, ) = target.call(abi.encodeWithSelector(selector, invoiceId, address(this), this.reconcileSingleInvoice.selector));
        if (!success) revert InvoiceSetPaidCallbackFailed();
    }

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @dev No checks needed for the creditor, as transferFrom will revert unless it gets executed by the nft owner (i.e. claim creditor)
    /// @param invoiceId The ID of the invoice to fund
    /// @param factorerUpfrontBps factorer specified upfront bps
    /// @param receiverAddress Address to receive the funds, if address(0) then funds go to msg.sender
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps, address receiverAddress) external returns(uint256) {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!redemptionQueue.isQueueEmpty()) revert RedemptionQueueNotEmpty();
        
        // Cache approvedInvoices in memory to reduce storage reads
        IBullaFactoringV2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        
        if (!approval.approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approval.feeParams.upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approval.validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapterV2.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoicesDetails.isCanceled) revert InvoiceCanceled();
        if (approval.initialPaidAmount != invoicesDetails.paidAmount) revert InvoicePaidAmountChanged();
        if (approval.creditor != invoicesDetails.creditor) revert InvoiceCreditorChanged();

        (uint256 fundedAmountGross, , , , uint256 protocolFee, uint256 fundedAmountNet) = FeeCalculations.calculateTargetFees(approval, invoicesDetails, factorerUpfrontBps, protocolFeeBps);   
        uint256 _totalAssets = totalAssets();
        uint256 atRiskPlusWithheldFees = fundedAmountGross + protocolFee;
        // needs to be gross amount here, because the fees will be locked, and we need liquidity to lock these
        if(atRiskPlusWithheldFees > _totalAssets) revert InsufficientFunds(_totalAssets, atRiskPlusWithheldFees);
        
        // Collect protocol fee to protocol fee balance
        protocolFeeBalance += protocolFee;

        // Update memory struct
        approval.fundedAmountGross = fundedAmountGross;
        approval.fundedAmountNet = fundedAmountNet;
        approval.fundedTimestamp = block.timestamp;
        // update upfrontBps with what was passed in the arg by the factorer
        approval.feeParams.upfrontBps = factorerUpfrontBps;
        approval.protocolFee = protocolFee;

        // Determine the actual receiver address - use msg.sender if receiverAddress is address(0)
        address actualReceiver = receiverAddress == address(0) ? msg.sender : receiverAddress;

        // Store the receiver address for future kickback payments
        approval.receiverAddress = actualReceiver;

        // Write back to storage once
        approvedInvoices[invoiceId] = approval;

        // transfer net funded amount to caller to the actual receiver
        assetAddress.safeTransfer(actualReceiver, fundedAmountNet);

        IERC721(invoiceProviderAdapter.getInvoiceContractAddress(invoiceId)).transferFrom(msg.sender, address(this), invoiceId);

        originalCreditors[invoiceId] = msg.sender;
        activeInvoices.push(invoiceId);

        // Add invoice to aggregate state tracking
        _addInvoiceToAggregate(approval.dailyInterestRate);
        
        // Add to capital at risk and withheld fees
        capitalAtRiskPlusWithheldFees += atRiskPlusWithheldFees;
        withheldFees += atRiskPlusWithheldFees - fundedAmountNet;

        _registerInvoiceCallback(invoiceId);

        emit InvoiceFunded(invoiceId, fundedAmountNet, msg.sender, approval.invoiceDueDate, factorerUpfrontBps, protocolFee);
        return fundedAmountNet;
    }

    /// @notice Provides a view of the pool's status, listing paid and impaired invoices, to be called by Gelato or alike
    /// @return impairedInvoiceIds An array of impaired invoice IDs
    function viewPoolStatus() external view returns (uint256[] memory impairedInvoiceIds) {
        uint256 activeCount = activeInvoices.length;
        
        impairedInvoiceIds = new uint256[](activeCount);
        
        uint256 impairedCount = 0;

        // Check active invoices
        for (uint256 i = 0; i < activeCount; i++) {
            uint256 invoiceId = activeInvoices[i];

            if (_isInvoiceImpaired(invoiceId)) {
                impairedInvoiceIds[impairedCount++] = invoiceId;
            }
        }

        // Overwrite the length of the arrays
        assembly {
            mstore(impairedInvoiceIds, impairedCount)
        }
    }

    /// @notice Increments the profit, and fee balances for a given invoice
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

        // Remove the invoice from activeInvoices array
        removeActivePaidInvoice(invoiceId);   
        
        // calculate kickback amount adjusting for true interest, protocol and admin fees
        IBullaFactoringV2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        (uint256 kickbackAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee) = FeeCalculations.calculateKickbackAmount(approval, invoice);

        incrementProfitAndFeeBalances(trueInterest, trueSpreadAmount, trueAdminFee);   

        address receiverAddress = approval.receiverAddress;
        
        if (kickbackAmount != 0) {
            assetAddress.safeTransfer(receiverAddress, kickbackAmount);
            emit InvoiceKickbackAmountSent(invoiceId, kickbackAmount, receiverAddress);
        }
        
        emit InvoicePaid(invoiceId, trueInterest, trueSpreadAmount, trueAdminFee, approval.fundedAmountNet, kickbackAmount, receiverAddress);
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

        IBullaFactoringV2.InvoiceApproval memory approval = approvedInvoices[invoiceId];
        // Calculate the funded amount for the invoice
        uint256 fundedAmount = approval.fundedAmountNet;

        // Calculate the number of days since funding
         uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? Math.mulDiv(block.timestamp - approval.fundedTimestamp, 1, 1 days, Math.Rounding.Floor) : 0;
        (uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee, ) = FeeCalculations.calculateFees(approval, daysSinceFunded, invoice);
        // Need to subtract payments since funding start
        uint256 paymentSinceFunding = invoice.paidAmount - approval.initialPaidAmount;
        int256 totalRefundOrPaymentAmount = int256(fundedAmount + trueInterest + trueSpreadAmount + trueAdminFee + approval.protocolFee) - int256(paymentSinceFunding);

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
        incrementProfitAndFeeBalances(trueInterest, trueSpreadAmount, trueAdminFee);

        delete originalCreditors[invoiceId];

        emit InvoiceUnfactored(invoiceId, originalCreditor, totalRefundOrPaymentAmount, trueInterest, trueSpreadAmount, trueAdminFee);
    }

    /// @notice Removes an invoice from the list of active invoices once it has been paid
    /// @param invoiceId The ID of the invoice to remove
    function removeActivePaidInvoice(uint256 invoiceId) private {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            if (activeInvoices[i] == invoiceId) {
                activeInvoices[i] = activeInvoices[activeInvoices.length - 1];
                activeInvoices.pop();
                
                uint256 dailyRate = approvedInvoices[invoiceId].dailyInterestRate;

                if (dailyRate > 0) {
                    // First, checkpoint to accumulate all interest up to this moment
                    _checkpointAccruedProfits();
                    
                    // Calculate this invoice's total accrued interest since it was funded
                    uint256 daysSinceFunding = (block.timestamp - approvedInvoices[invoiceId].fundedTimestamp) / 1 days;
                    uint256 invoiceAccruedInterest = dailyRate * daysSinceFunding;
                    
                    // Remove this invoice's accrued interest from the checkpoint
                    accruedProfitsAtCheckpoint -= invoiceAccruedInterest;
                    
                    // Remove this invoice's daily rate from future calculations
                    totalDailyInterestRate -= dailyRate;
                }
                uint256 atRiskPlusWithheldFees = approvedInvoices[invoiceId].fundedAmountGross + approvedInvoices[invoiceId].protocolFee;

                // Remove from capital at risk plus withheld fees
                capitalAtRiskPlusWithheldFees -= atRiskPlusWithheldFees;

                // Remove from withheld fees
                withheldFees -= atRiskPlusWithheldFees - approvedInvoices[invoiceId].fundedAmountNet;

                return;
            }
        }

        revert InvoiceNotActive();
    }

    /// @notice Calculates the available assets in the fund net of fees and impair reserve
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

    /// @notice Retrieves the fund information
    /// @return FundInfo The fund information
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
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);

        uint256 sharesToRedeem = redemptionQueue.isQueueEmpty() ? Math.min(shares, maxRedeem(_owner)) : 0;
        uint256 redeemedAssets = 0;
        
        if (sharesToRedeem > 0) {
            redeemedAssets = super.redeem(sharesToRedeem, receiver, _owner);
            totalWithdrawals += redeemedAssets;
        }

        uint256 queuedShares = shares - sharesToRedeem;
        if (queuedShares > 0) {
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
        if (!redeemPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!redeemPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);
        
        uint256 assetsToWithdraw = redemptionQueue.isQueueEmpty() ? Math.min(assets, maxWithdraw(_owner)) : 0;
        uint256 redeemedShares = 0;
        
        if (assetsToWithdraw > 0) {
            redeemedShares = super.withdraw(assetsToWithdraw, receiver, _owner);
            totalWithdrawals += assetsToWithdraw;
        }

        uint256 queuedAssets = assets - assetsToWithdraw;
        if (queuedAssets > 0) {
            // Queue the remaining assets for future withdrawal
            // The RedemptionQueued event is emitted by the redemptionQueue.queueRedemption call
            redemptionQueue.queueRedemption(_owner, receiver, 0, queuedAssets);
        }
        
        return redeemedShares;
    }

    /// @notice Process queued redemptions when liquidity becomes available
    function processRedemptionQueue() external {
        IRedemptionQueue.QueuedRedemption memory redemption = redemptionQueue.getNextRedemption();
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