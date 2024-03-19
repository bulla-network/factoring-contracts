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

/// @title Bulla Factoring Fund POC
/// @author @solidoracle
/// @notice  
contract BullaFactoring is IBullaFactoring, ERC20, ERC4626, Ownable {
    using Math for uint256;

    address public bullaDao;
    uint16 public protocolFeeBps;
    uint16 public adminFeeBps;
    uint256 public bullaDaoFeeBalance;
    uint256 public adminFeeBalance;
    IERC20 public assetAddress;
    IInvoiceProviderAdapter public invoiceProviderAdapter;
    uint256 private totalDeposits; 
    uint256 private totalWithdrawals;
    address public underwriter;

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
    error InvoiceAlreadyPaid();
    error CallerNotOriginalCreditor();
    error InvalidPercentage();
    error CallerNotBullaDao();
    error NoFeesToWithdraw();
    error FeeWithdrawalFailed();
    error InvalidAddress();

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
        uint16 _adminFeeBps
    ) ERC20('Bulla Fund Token', 'BFT') ERC4626(_asset) Ownable(msg.sender) {
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
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

    /// @notice Approves an invoice for funding, can only be called by the underwriter
    /// @param invoiceId The ID of the invoice to approve
    function approveInvoice(uint256 invoiceId, uint16 _interestApr, uint16 _upfrontBps) public {
        if (_upfrontBps <= 0 || _upfrontBps > 10000) revert InvalidPercentage();
        if (msg.sender != underwriter) revert CallerNotUnderwriter();
        approvedInvoices[invoiceId] = InvoiceApproval({
            approved: true,
            validUntil: block.timestamp + approvalDuration,
            invoiceSnapshot: invoiceProviderAdapter.getInvoiceDetails(invoiceId),
            fundedTimestamp: 0,
            interestApr: _interestApr,
            upfrontBps: _upfrontBps,
            fundedAmountGross: 0,
            fundedAmountNet: 0,
            adminFee: 0
        });
        emit InvoiceApproved(invoiceId);
    }

    /// @notice Calculates the kickback amount for a given funded amount allowing early payment
    /// @param invoiceId The ID of the invoice for which to calculate the kickback amount
    /// @return The calculated kickback amount
    function calculateKickbackAmount(uint256 invoiceId) private returns (uint256) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        InvoiceApproval memory approval = approvedInvoices[invoiceId];
       
        uint256 daysSinceFunded = (block.timestamp > approval.fundedTimestamp) ? (block.timestamp - approval.fundedTimestamp) / 60 / 60 / 24 : 0;
        daysSinceFunded = daysSinceFunded +1;

        uint256 interestAprBps = approval.interestApr;

        // notice it is milli bps, so 1000 mbps = 1 bps
        uint256 interestAprMbps = interestAprBps*1000;

        // Calculate the true APR discount for the actual payment period
        uint256 trueInterestRateMbps = Math.mulDiv(interestAprMbps, daysSinceFunded, 365);

        // calculate the true APR discount with protocols fee
        uint256 trueInterestAndProtocolFeeMbps =  Math.mulDiv(trueInterestRateMbps, (10000 + protocolFeeBps), 10000);

        // cap interest to max available to distribute, excluding the targetInterest and targetProtocolFee
        uint256 interestCap = approval.fundedAmountGross - approval.adminFee;

        // Calculate the true interest and protocol fee
        uint256 trueInterestAndProtocolFee = Math.min(interestCap, Math.mulDiv(interestCap, trueInterestAndProtocolFeeMbps , 1000_0000));

        // Calculate the true interest
        uint256 trueInterest = Math.mulDiv(trueInterestAndProtocolFee, trueInterestRateMbps, trueInterestAndProtocolFeeMbps);

        // Calculate true protocol fee
        uint256 trueProtocolFee = trueInterestAndProtocolFee - trueInterest;

        // Realise the protocol fee
        bullaDaoFeeBalance += trueProtocolFee;

        // Calculate the total amount that should have been paid to the original creditor
        uint256 totalDueToCreditor = invoice.faceValue - approval.adminFee - trueInterest  - trueProtocolFee;
        // Retrieve the funded amount from the approvedInvoices mapping
        uint256 fundedAmount = approval.fundedAmountNet;
        // Calculate the kickback amount
        uint256 kickbackAmount = totalDueToCreditor > fundedAmount ? totalDueToCreditor - fundedAmount : 0;

        return kickbackAmount;
    }

    /// @notice Calculates the total realized gain or loss from paid and impaired invoices
    /// @return The total realized gain adjusted for losses
    function calculateRealizedGainLoss() public view returns (uint256) {
        uint256 realizedGains = 0;
        // Consider gains from paid invoices
        for (uint256 i = 0; i < paidInvoicesIds.length; i++) {
            uint256 invoiceId = paidInvoicesIds[i];
            realizedGains += paidInvoicesGain[invoiceId];
        }

        // Consider impaired invoices from activeInvoices
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            if (isInvoiceImpaired(invoiceId)) {
                uint256 fundedAmount = approvedInvoices[invoiceId].fundedAmountNet;

                if (realizedGains < fundedAmount) revert DeductionsExceedsRealisedGains();
                realizedGains -= fundedAmount;
            }
        }
        return realizedGains;
    }

    /// @notice Calculates the capital account balance, including deposits, withdrawals, and realized gains/losses
    /// @return The calculated capital account balance
    function calculateCapitalAccount() public view returns (uint256) {
        uint256 realizedGainLoss = calculateRealizedGainLoss();
        uint256 capitalAccount = totalDeposits - totalWithdrawals + realizedGainLoss;
        return capitalAccount;
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

        assetAddress.transferFrom(from, address(this), assets);
        uint256 shares = convertToShares(assets);
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

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @param invoiceId The ID of the invoice to fund
    /// @param factorerUpfrontBps factorer specified upfront bps
    function fundInvoice(uint256 invoiceId, uint16 factorerUpfrontBps) public {
        if (!factoringPermissions.isAllowed(msg.sender)) revert UnauthorizedFactoring(msg.sender);
        if (!approvedInvoices[invoiceId].approved) revert InvoiceNotApproved();
        if (factorerUpfrontBps > approvedInvoices[invoiceId].upfrontBps || factorerUpfrontBps == 0) revert InvalidPercentage();
        if (block.timestamp > approvedInvoices[invoiceId].validUntil) revert ApprovalExpired();
        IInvoiceProviderAdapter.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        if (invoicesDetails.isCanceled) revert InvoiceCanceled();
        if (approvedInvoices[invoiceId].invoiceSnapshot.paidAmount != invoicesDetails.paidAmount) revert InvoicePaidAmountChanged();

        IInvoiceProviderAdapter.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);

        // calculate target interest, fees and net funded amount
        uint256 fundedAmountGross_ = Math.mulDiv(invoice.faceValue, factorerUpfrontBps, 10000);
        uint256 adminFeeAmount = Math.mulDiv(invoice.faceValue, adminFeeBps, 10000);        
        adminFeeBalance += adminFeeAmount;
        uint256 daysUntilDue = (invoice.dueDate - block.timestamp) / 60 / 60 / 24;
        // Start counting the first second
        daysUntilDue = daysUntilDue + 1;
        uint256 targetInterestRate = Math.mulDiv(approvedInvoices[invoiceId].interestApr, daysUntilDue , 365); 
        uint256 targetInterest = Math.mulDiv(fundedAmountGross_,targetInterestRate, 10000); 
        uint256 targetProtocolFee = Math.mulDiv( targetInterest ,protocolFeeBps, 10000);
        uint256 fundedAmountNet = fundedAmountGross_ - adminFeeAmount - targetInterest - targetProtocolFee;

        // store values in approvedInvoices
        approvedInvoices[invoiceId].fundedAmountGross = fundedAmountGross_;
        approvedInvoices[invoiceId].fundedAmountNet = fundedAmountNet;
        approvedInvoices[invoiceId].adminFee = adminFeeAmount;
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
    }

    /// @notice Provides a view of the pool's status, listing paid and impaired invoices, to be called by Gelato or alike
    /// @return paidInvoices An array of paid invoice IDs
    /// @return impairedInvoices An array of impaired invoice IDs
    function viewPoolStatus() public view returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices) {
        uint256 activeCount = activeInvoices.length;
        uint256[] memory tempPaidInvoices = new uint256[](activeCount);
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

    /// @notice Reconciles the list of active invoices with those that have been paid, updating the fund's records
    /// @dev This function should be called when viewPoolStatus returns some updates, to ensure accurate accounting
    function reconcileActivePaidInvoices() public onlyOwner {
        (uint256[] memory paidInvoiceIds, ) = viewPoolStatus();

        for (uint256 i = 0; i < paidInvoiceIds.length; i++) {
            uint256 invoiceId = paidInvoiceIds[i];

            // Retrieve the faceValue for the invoice from the external contract
            IInvoiceProviderAdapter.Invoice memory externalInvoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
            uint256 faceValue = externalInvoice.faceValue;

            // Calculate and store the factoring gain
            uint256 fundedAmount = approvedInvoices[invoiceId].fundedAmountNet;
            // calculate kickback amount adjusting for true interest and fees
            uint256 kickbackAmount = calculateKickbackAmount(invoiceId);
            uint256 factoringGain = faceValue - fundedAmount - kickbackAmount;

            // store factoring gain
            paidInvoicesGain[invoiceId] = factoringGain;

            // Add the invoice ID to the paidInvoicesIds array
            paidInvoicesIds.push(invoiceId);

            // Disperse kickback amount to the original creditor
            address originalCreditor = originalCreditors[invoiceId];            
            if (kickbackAmount != 0) {
                require(assetAddress.transfer(originalCreditor, kickbackAmount), "Kickback transfer failed");
                emit InvoiceKickbackAmountSent(invoiceId, kickbackAmount, originalCreditor);
            }

            // Remove the invoice from activeInvoices array
            removeActivePaidInvoice(invoiceId);   
        }
        emit ActivePaidInvoicesReconciled(paidInvoiceIds);
    }

    /// @notice Unfactors an invoice, returning the invoice NFT to the original creditor and refunding the funded amount
    /// @param invoiceId The ID of the invoice to unfactor
    function unfactorInvoice(uint256 invoiceId) public {
        if (isInvoicePaid(invoiceId)) revert InvoiceAlreadyPaid();
        address originalCreditor = originalCreditors[invoiceId];
        if (originalCreditor != msg.sender) revert CallerNotOriginalCreditor();

        // Calculate the funded amount for the invoice
        uint256 fundedAmount = approvedInvoices[invoiceId].fundedAmountNet;

        // Calculate the number of days since funding
        uint256 daysSinceFunding = (block.timestamp - approvedInvoices[invoiceId].fundedTimestamp) / 60 / 60 / 24;
        uint256 daysOfInterestToCharge = daysSinceFunding + 1;

        // Calculate interest to charge
        uint256 accruedInterest = Math.mulDiv(approvedInvoices[invoiceId].interestApr, daysOfInterestToCharge, 365); // APR adjusted for the number of days
        uint256 interestToCharge = Math.mulDiv(fundedAmount, accruedInterest, 10000); // Calculate interest
        uint256 totalRefundAmount = fundedAmount > interestToCharge ?  fundedAmount - interestToCharge : 0;

        // Refund the funded amount to the fund from the original creditor
        require(assetAddress.transferFrom(originalCreditor, address(this), totalRefundAmount), "Refund transfer failed");

        // Transfer the invoice NFT back to the original creditor
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        IERC721(invoiceContractAddress).transferFrom(address(this), originalCreditor, invoiceId);

        // Update the contract's state to reflect the unfactoring
        removeActivePaidInvoice(invoiceId); 
        delete originalCreditors[invoiceId];

        emit InvoiceUnfactored(invoiceId, originalCreditor);
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
    function totalFundedAmountForActiveInvoices() internal view returns (uint256) {
        uint256 totalFunded = 0;
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            uint256 invoiceId = activeInvoices[i];
            totalFunded += approvedInvoices[invoiceId].fundedAmountNet;
        }
        return totalFunded;
    }

    /// @notice Calculates the available assets in the fund that are not currently at risk due to active invoice funding
    /// @return The amount of assets available for withdrawal or new investments, excluding funds allocated to active invoices
    function availableAssets() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        uint256 atRiskCapital = totalFundedAmountForActiveInvoices(); 

        // Ensures we don't consider at-risk capital as part of the withdrawable assets, as well as fees
        return totalAssetsInFund > atRiskCapital ? totalAssetsInFund - atRiskCapital - bullaDaoFeeBalance - adminFeeBalance : 0;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() public view returns (uint256) {
        uint256 currentPricePerShare = pricePerShare();
        // Calculate the maximum withdrawable shares based on available assets and current price per share
        uint256 maxWithdrawableShares = Math.mulDiv(availableAssets(), SCALING_FACTOR, currentPricePerShare);
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
            assets = Math.mulDiv(maxWithdrawableShares, pricePerShare(), SCALING_FACTOR);
        } else {
            uint256 currentPricePerShare = pricePerShare();
            assets = Math.mulDiv(shares, currentPricePerShare, SCALING_FACTOR);
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
        uint256 feeAmount = bullaDaoFeeBalance;
        if (feeAmount == 0) revert NoFeesToWithdraw();
        bullaDaoFeeBalance = 0;
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

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert FunctionNotSupported();
    }

    function mint(uint256, address) public pure override returns (uint256){
        revert FunctionNotSupported();
    }
}