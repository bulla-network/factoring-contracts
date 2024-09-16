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
/// @notice Bulla Factoring Fund is a ERC4626 compatible fund that allows for the factoring of invoices
contract BullaFactoring is IBullaFactoring, ERC20, ERC4626, Ownable {
    using Math for uint256;

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
    IInvoiceProviderAdapter public invoiceProviderAdapter;
    /// @notice Address of the underwriter, trusted to approve invoices
    address public underwriter;
    /// @notice Timestamp of the fund's creation
    uint256 public creationTimestamp;
    /// @notice Reserve amount for impairment
    uint256 public impairReserve;
    /// @notice Name of the factoring pool
    string public poolName;
    /// @notice Tax rate in basis points
    uint16 public taxBps;
    /// @notice Accumulated tax balance
    uint256 public taxBalance;
    /// @notice Target yield in basis points
    uint16 public targetYieldBps;

    /// @notice Scaling factor for the token
    uint256 public SCALING_FACTOR;
    /// @notice Grace period for invoices
    uint256 public gracePeriodDays = 60;

    /// @notice Permissions contracts for deposit and factoring
    Permissions public depositPermissions;
    Permissions public factoringPermissions;

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

    /// Mapping from invoice ID to tax amount
    mapping(uint256 => uint256) public paidInvoiceTax;

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
    error InvoiceCannotBePaid();

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
        if (invoiceSnapshot.faceValue - invoiceSnapshot.paidAmount == 0) revert InvoiceCannotBePaid();

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
            trueFaceValue: invoiceSnapshot.faceValue - invoiceSnapshot.paidAmount
        });
        emit InvoiceApproved(invoiceId, _interestApr, _upfrontBps, _validUntil, minDaysInterestApplied);
    }

    /// @notice Calculates the interest, protocol fee and admin fee for a given invoice approval over a specified number of days
    /// @param approval The invoice approval details
    /// @param daysOfInterest The number of days over which interest is calculated
    /// @return interest The calculated interest amount
    /// @return protocolFee The calculated protocol fee amount
    /// @return adminFee The calculated admin fee amount
    function calculateFees(InvoiceApproval memory approval, uint256 daysOfInterest) private view returns (uint256 interest, uint256 protocolFee, uint256 adminFee) {
        uint256 interestAprBps = approval.interestApr;
        uint256 interestAprMbps = interestAprBps * 1000;

        // Calculate the APR discount for the payment period
        // millibips used due to the small nature of the fees
        uint256 interestRateMbps = Math.mulDiv(interestAprMbps, daysOfInterest, 365);

        // calculate the APR discount with protocols fee
        // millibips used due to the small nature of the fees
        uint256 interestAndProtocolFeeMbps = Math.mulDiv(interestRateMbps, (10000 + protocolFeeBps), 10000);
        
        // Calculate the admin fee rate
        uint256 adminFeeRateMbps = Math.mulDiv(adminFeeBps * 1000, daysOfInterest, 365);
        
        // Calculate the total fee rate Mbps (interest + protocol fee + admin fee)
        uint256 totalFeeRateMbps = interestAndProtocolFeeMbps + adminFeeRateMbps;
        
        // cap total fees to max available to distribute
        uint256 capTotalFees = approval.trueFaceValue - approval.fundedAmountNet;

        // Calculate total fees
        uint256 totalFees = Math.min(capTotalFees, Math.mulDiv(approval.trueFaceValue, totalFeeRateMbps, 1000_0000));
        
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
    
        uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? (block.timestamp - approval.fundedTimestamp) / 60 / 60 / 24 : 0;
        uint256 daysOfInterest = daysSinceFunded = Math.max(daysSinceFunded + 1, approval.minDaysInterestApplied);

        (trueInterest, trueProtocolFee, trueAdminFee) = calculateFees(approval, daysOfInterest);

        // Calculate the total amount that should have been paid to the original creditor
        uint256 totalDueToCreditor = approval.trueFaceValue - trueAdminFee - trueInterest - trueProtocolFee;

        // Calculate the kickback amount
        kickbackAmount = totalDueToCreditor > approval.fundedAmountNet ? totalDueToCreditor - approval.fundedAmountNet : 0;

        return (kickbackAmount, trueInterest, trueProtocolFee, trueAdminFee);
    }

    /// @notice Calculates the capital account, which represents the total value of the fund, including both liquid and deployed assets, as well as expected future earnings
    /// @return The calculated capital account balance
    function calculateCapitalAccount() public view returns (uint256) {
        return availableAssets()
            + sumTargetFeesForActiveInvoices() // adding back since it's withheld in availableAssets
            + deployedCapitalForActiveInvoicesExcludingImpaired()
            + getNetUnrealizedProfitFromActiveInvoices();
    }

    /// @notice Calculates the current price per share of the fund, 
    /// @return The current price per share, scaled to the underlying asset's decimal places
    function pricePerShare() public view returns (uint256) {
        uint256 sharesOutstanding = totalSupply();
        if (sharesOutstanding == 0) {
            return SCALING_FACTOR;
        }

        uint256 capitalAccount = calculateCapitalAccount();
        return Math.mulDiv(capitalAccount, SCALING_FACTOR, sharesOutstanding);
    }

    /// @notice Converts a given amount of assets to the equivalent amount of shares
    /// @param assets The amount of assets to convert
    /// @return The equivalent amount of shares
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets;
        }
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 scaledCapitalAccount = capitalAccount * SCALING_FACTOR;
        return Math.mulDiv(assets * SCALING_FACTOR, supply, scaledCapitalAccount);
    }

    /// @notice Converts a given amount of shares to the equivalent amount of assets
    /// @param shares The amount of shares to convert
    /// @return The equivalent amount of assets
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        uint256 scaledShares = shares * SCALING_FACTOR;
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 scaledCapitalAccount = capitalAccount * SCALING_FACTOR;
        uint256 assetsScaled = Math.mulDiv(scaledShares, scaledCapitalAccount, supply);
        return assetsScaled / SCALING_FACTOR / SCALING_FACTOR;
    }

    /// @notice Calculates gross unrealized profit for an active invoice 
    /// @param invoiceId The invoice id
    /// @return trueInterest the interest due on the invoice at the current date, grossUnrealizedProfit the unrealized profit on this invoice to date.
    function getGrossUnrealizedProfitOnActiveInvoice(uint256 invoiceId) private view returns (uint256, uint256) {
        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        (,uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) = calculateKickbackAmount(invoiceId);
        uint256 paymentSinceFunding = getPaymentsOnInvoiceSinceFunding(invoiceId);
        
        
        // Any amount paid lower than this amount is not proft 
        uint256 profitFloor = approval.fundedAmountNet + trueProtocolFee + trueAdminFee;

        uint256 grossUnrealizedProfit = profitFloor >= paymentSinceFunding ? 0 : Math.min(trueInterest, paymentSinceFunding - profitFloor);
        return (trueInterest, grossUnrealizedProfit);
    }

    /// @notice Calculates the total accrued profits from all active invoices
    /// @dev Iterates through all active invoices, calculates interest for each, deducts taxes, and sums the net accrued interest
    /// @return accruedProfits The total net accrued profits across all active invoices
    function calculateAccruedProfits() public view returns (uint256 accruedProfits) {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];

            (uint256 trueInterest, uint256 grossUnrealizedProfit) = getGrossUnrealizedProfitOnActiveInvoice(invoiceId);
            uint256 grossAccruedInterestOnRemainingInvoiceAmount = grossUnrealizedProfit >= trueInterest ? 0 : trueInterest - grossUnrealizedProfit;

            // Deduct tax from the accrued interest
            uint256 taxAmount = calculateTax(grossAccruedInterestOnRemainingInvoiceAmount);
            uint256 netAccruedInterest = grossAccruedInterestOnRemainingInvoiceAmount - taxAmount;

            accruedProfits += netAccruedInterest;
        }

        return accruedProfits;
    }

    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 sharesOutstanding = totalSupply();
        uint256 shares;

        if(sharesOutstanding == 0) {
            shares = assets;
        } else {
            uint256 accruedProfits = calculateAccruedProfits();
            shares = Math.mulDiv(assets * SCALING_FACTOR, sharesOutstanding, capitalAccount + accruedProfits) / SCALING_FACTOR;
        }

        return shares;
    }

    /// @notice Helper function to handle the logic of depositing assets in exchange for fund shares
    /// @param from The address making the deposit
    /// @param receiver The address to receive the fund shares
    /// @param assets The amount of assets to deposit
    /// @return The number of shares issued for the deposit
    function _deposit(address from, address receiver, uint256 assets) private returns (uint256) {
        if (!depositPermissions.isAllowed(from)) revert UnauthorizedDeposit(from);
        
        uint256 shares = previewDeposit(assets);
        assetAddress.transferFrom(from, address(this), assets);

        _mint(receiver, shares);
        return shares;
    }

    /// @notice Allows for the deposit of assets in exchange for fund shares with an attachment
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the fund shares
    /// @param attachment The attachment data for the deposit
    /// @return The number of shares issued for the deposit
    function depositWithAttachment(uint256 assets, address receiver, Multihash calldata attachment) external returns (uint256) {
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
    /// @return adminFee The target calculated admin fee
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

        (targetInterest, targetProtocolFee, adminFee) = calculateFees(approval, daysUntilDue);

        uint256 totalFees = adminFee + targetInterest + targetProtocolFee;
        netFundedAmount = fundedAmountGross - totalFees;

        return (fundedAmountGross, adminFee, targetInterest, targetProtocolFee, netFundedAmount);
    }

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @param invoiceId The ID of the invoice to fund
    /// @param factorerUpfrontBps factorer specified upfront bps
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps) external returns(uint256) {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!approvedInvoices[invoiceId].approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approvedInvoices[invoiceId].upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approvedInvoices[invoiceId].validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapter.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
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
    /// @param trueAdminFee The true admin fee amount for the invoice
    function incrementProfitTaxAndFeeBalances(uint256 invoiceId, uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) private {
        // Add the admin fee to the balance
        adminFeeBalance += trueAdminFee;
        
        uint256 taxAmount = calculateTax(trueInterest);

        // Update storage variables
        paidInvoiceTax[invoiceId] = taxAmount;
        taxBalance += taxAmount;
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
            
            // calculate kickback amount adjusting for true interest, protocol and admin fees
            (uint256 kickbackAmount, uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) = calculateKickbackAmount(invoiceId);

            incrementProfitTaxAndFeeBalances(invoiceId, trueInterest, trueProtocolFee, trueAdminFee);   

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
            emit InvoicePaid(invoiceId, trueInterest, trueProtocolFee, trueAdminFee, approval.fundedAmountNet, kickbackAmount, originalCreditor);
        }
        emit ActivePaidInvoicesReconciled(paidInvoiceIds);
    }

    /// @notice Calculates the tax amount based on a specified payment amount and the current tax basis points (bps).
    /// @param amount The amount of the payment on which tax is to be calculated.
    /// @return The calculated tax amount.
    function calculateTax(uint256 amount) internal view returns (uint256) {
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
    function unfactorInvoice(uint256 invoiceId) external {
        if (isInvoicePaid(invoiceId)) revert InvoiceAlreadyPaid();
        address originalCreditor = originalCreditors[invoiceId];
        if (originalCreditor != msg.sender) revert CallerNotOriginalCreditor();

        InvoiceApproval memory approval = approvedInvoices[invoiceId];
        // Calculate the funded amount for the invoice
        uint256 fundedAmount = approval.fundedAmountNet;

        // Calculate the number of days since funding
        uint256 daysSinceFunding = (block.timestamp - approval.fundedTimestamp) / 60 / 60 / 24;
        uint256 daysOfInterestToCharge = daysSinceFunding + 1;
        
        (uint256 trueInterest, uint256 trueProtocolFee, uint256 trueAdminFee) = calculateFees(approval, daysOfInterestToCharge);
        uint256 totalRefundAmount = fundedAmount + trueInterest + trueProtocolFee + trueAdminFee;

        // Refund the funded amount to the fund from the original creditor
        require(assetAddress.transferFrom(originalCreditor, address(this), totalRefundAmount), "Refund transfer failed");

        // Transfer the invoice NFT back to the original creditor
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        IERC721(invoiceContractAddress).transferFrom(address(this), originalCreditor, invoiceId);

        // Update the contract's state to reflect the unfactoring
        removeActivePaidInvoice(invoiceId);
        incrementProfitTaxAndFeeBalances(invoiceId, trueInterest, trueProtocolFee, trueAdminFee);

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

    function getPaymentsOnInvoiceSinceFunding(uint256 invoiceId) private view returns (uint256) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

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

    /// @notice Calculates the net unrealized profits of active invoices, excludes impaired invoices
    /// @return The sum of all net unrealized profits of active invoices
    function getNetUnrealizedProfitFromActiveInvoices() private view returns (uint256) {
        uint256 netUnrealizedProfit = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];

            if(!isInvoiceImpaired(invoiceId))  {
                (,uint256 grossUnrealizedProfit) = getGrossUnrealizedProfitOnActiveInvoice(invoiceId);
                netUnrealizedProfit += grossUnrealizedProfit == 0 ? 0 : grossUnrealizedProfit - calculateTax(grossUnrealizedProfit);
            }
        }

        return netUnrealizedProfit;
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

    /// @notice Calculates the available assets in the fund net of fees, impair reserve and tax
    /// @return The amount of assets available for withdrawal or new investments, excluding funds allocated to active invoices
    function availableAssets() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        return totalAssetsInFund
                - getAllIncomingPaymentsForActiveInvoices() // payments assigned to unpaid invoices, accounted for in total assets but not available for profit distribution
                - sumTargetFeesForActiveInvoices() // withheld projected fees, accounted for in total assets but not available for profit distribution
                - impairReserve
                - taxBalance
                - protocolFeeBalance
                - adminFeeBalance;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() public view returns (uint256) {
        uint256 availableAssetAmount = availableAssets();
        uint256 capitalAccount = calculateCapitalAccount();

        if (capitalAccount == 0) {
            return 0;
        }

        uint256 maxWithdrawableShares = convertToShares(availableAssetAmount);
        return maxWithdrawableShares;
    }

    /** @dev See {IERC4626-previewRedeem}. */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
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
            assets = availableAssets();
            shares = maxWithdrawableShares;
        } else {
            assets = convertToAssets(shares);
        }
        _withdraw(from, receiver, owner, assets, shares);
        return assets;
    }

    /// @notice Redeems shares for underlying assets with an attachment, transferring the assets to the specified receiver
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param owner The owner of the shares being redeemed
    /// @param attachment The attachment data for the redemption
    /// @return The amount of assets redeemed
    function redeemWithAttachment(uint256 shares, address receiver, address owner, Multihash calldata attachment) external returns (uint256) {
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
    function withdrawProtocolFees() external {
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

    /// @notice Sets the tax basis points (bps)
    /// @param _newTaxBps The new tax rate in basis points
    /// @dev This function can only be called by the contract owner
    function setTaxBps(uint16 _newTaxBps) public onlyOwner {
        if (_newTaxBps > 10000) revert InvalidPercentage();
        taxBps = _newTaxBps;
        emit TaxBpsChanged(taxBps, _newTaxBps);
    }

    /** @dev See {IERC4626-previewWithdraw}. */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Allows withdrawal of assets from the fund
    /// @param assets The amount of assets to withdraw
    /// @param receiver The address to receive the withdrawn assets
    /// @param owner The owner of the shares being burned
    /// @return The amount of assets withdrawn
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 availableAssetAmount = availableAssets();
        uint256 shares;
        if (assets > availableAssetAmount) {
            assets = availableAssetAmount;
            shares = convertToShares(availableAssetAmount);
        } else {
            shares = convertToShares(assets);
        }
        _withdraw(msg.sender, receiver, owner, assets, shares);
        emit AssetsWithdrawn(_msgSender(), receiver, owner, assets, shares);

        return assets;
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
        if (_targetYieldBps > 10000) revert InvalidPercentage();
        targetYieldBps = _targetYieldBps;
        emit TargetYieldChanged(_targetYieldBps);
    }

    /// @notice Retrieves the fund information
    /// @return FundInfo The fund information
    function getFundInfo() external view returns (FundInfo memory) {
        uint256 fundBalance = availableAssets();
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