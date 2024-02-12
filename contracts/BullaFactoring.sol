// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import {console} from "../lib/forge-std/src/console.sol";
import "./interfaces/IInvoiceProviderAdapter.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';


/// @title Bulla Factoring Fund POC
/// @author @solidoracle
/// @notice  
contract BullaFactoring is ERC20, ERC4626, Ownable {
    using Math for uint256;

    IERC20 public assetAddress;
    IInvoiceProviderAdapter public invoiceProviderAdapter;
    uint256 private totalDeposits; 
    uint256 private totalWithdrawals;
    uint256 public fundingPercentage = 9000; // 90% in bps
    address public underwriter;

    uint256 public SCALING_FACTOR;
    uint256 public gracePeriodDays = 60;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => uint256) public paidInvoicesGain;

    /// Mapping from invoice ID to original creditor's address
    mapping(uint256 => address) public originalCreditors;

    struct InvoiceApproval {
        bool approved;
        IInvoiceProviderAdapter.Invoice invoiceSnapshot;
        uint256 validUntil;
    }

    mapping(uint256 => InvoiceApproval) public approvedInvoices;
    uint256 public approvalDuration = 1 hours;

    /// Array to hold the IDs of all active invoices
    uint256[] public activeInvoices;

    // Array to track IDs of paid invoices
    uint256[] private paidInvoicesIds;

    /// @param _asset underlying supported stablecoin asset for deposit 
    /// @param _invoiceProviderAdapter adapter for invoice provider
    /// @param _underwriter address of the underwriter
    constructor(IERC20 _asset, IInvoiceProviderAdapter _invoiceProviderAdapter, address _underwriter) ERC20('Bulla Fund Token', 'BFT') ERC4626(_asset) Ownable(msg.sender) {
        assetAddress = _asset;
        SCALING_FACTOR = 10**uint256(ERC20(address(assetAddress)).decimals());
        invoiceProviderAdapter = _invoiceProviderAdapter;
        underwriter = _underwriter; 
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

    /// @notice Approves an invoice for funding, can only be called by the underwriter
    /// @param invoiceId The ID of the invoice to approve
    function approveInvoice(uint256 invoiceId) public {
        require(msg.sender == underwriter, "Caller is not the underwriter");
        approvedInvoices[invoiceId] = InvoiceApproval({
            approved: true,
            validUntil: block.timestamp + approvalDuration,
            invoiceSnapshot: invoiceProviderAdapter.getInvoiceDetails(invoiceId)
        });
    }

    /// @notice Calculates the amount to be funded for a given invoice based on its face value and the funding percentage
    /// @param invoiceId The ID of the invoice for which to calculate the funded amount
    /// @return The calculated amount to be funded
    function calculateFundedAmount(uint256 invoiceId) private view returns (uint256) {
        IInvoiceProviderAdapter.Invoice memory invoice = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        return Math.mulDiv(invoice.faceValue, fundingPercentage, 10000);
    }

    /// @notice Calculates the total realized gain or loss from paid and impaired invoices
    /// @return The total realized gain adjusted for losses
    function calculateRealizedGainLoss() private view returns (uint256) {
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
                uint256 fundedAmount = calculateFundedAmount(invoiceId);
                require(realizedGains >= fundedAmount, "Impaired invoice deduction exceeds realized gains");
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

    /// @notice Allows for the deposit of assets in exchange for fund shares
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the fund shares
    /// @return The number of shares issued for the deposit
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = convertToShares(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        
        totalDeposits += assets;

        return shares;
    }

    /// @notice Funds a single invoice, transferring the funded amount from the fund to the caller and transferring the invoice NFT to the fund
    /// @param invoiceId The ID of the invoice to fund
    function fundInvoice(uint256 invoiceId) public {
        require(approvedInvoices[invoiceId].approved, "Invoice not approved by underwriter");
        require(block.timestamp <= approvedInvoices[invoiceId].validUntil, "Approval expired");
        IInvoiceProviderAdapter.Invoice memory invoicesDetails = invoiceProviderAdapter.getInvoiceDetails(invoiceId);
        require(!invoicesDetails.isCanceled, "Invoice cannot be cancelled");
        require(approvedInvoices[invoiceId].invoiceSnapshot.paidAmount == invoicesDetails.paidAmount, "Invoice should not have been paid between approval and funding");

        uint256 fundedAmount = calculateFundedAmount(invoiceId);
        assetAddress.transfer(msg.sender, fundedAmount);

        // transfer invoice nft ownership to vault
        address invoiceContractAddress = invoiceProviderAdapter.getInvoiceContractAddress();
        IERC721(invoiceContractAddress).transferFrom(msg.sender, address(this), invoiceId);

        originalCreditors[invoiceId] = msg.sender;
        activeInvoices.push(invoiceId);
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
            uint256 fundedAmount = calculateFundedAmount(invoiceId);
            uint256 factoringGain = faceValue - fundedAmount;
            paidInvoicesGain[invoiceId] = factoringGain;

            // Add the invoice ID to the paidInvoicesIds array
            paidInvoicesIds.push(invoiceId);

            // Remove the invoice from activeInvoices array
            removeActivePaidInvoice(invoiceId);
        }
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

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        uint256 currentPricePerShare = pricePerShare();
        // Calculate the maximum withdrawable shares based on total assets and current price per share
        uint256 maxWithdrawableShares = Math.mulDiv(totalAssetsInFund, SCALING_FACTOR, currentPricePerShare);
        return maxWithdrawableShares;
    }

    /// @notice Redeems shares for underlying assets, transferring the assets to the specified receiver
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param owner The owner of the shares being redeemed
    /// @return The amount of assets redeemed
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 maxWithdrawableShares = maxRedeem();
        uint256 assets;
        if (shares > maxWithdrawableShares) {
            uint256 maxWithdrawableAmount = totalAssets();   
            _withdraw(_msgSender(), receiver, owner, maxWithdrawableAmount, maxWithdrawableShares);
            assets = Math.mulDiv(maxWithdrawableShares, pricePerShare(), SCALING_FACTOR);
        } else {
            uint256 currentPricePerShare = pricePerShare();
            assets = Math.mulDiv(shares, currentPricePerShare, SCALING_FACTOR);
            _withdraw(_msgSender(), receiver, owner, assets, shares);
        }
        totalWithdrawals += assets;
        return assets;
    }

    /// @notice Sets the funding percentage for new invoices
    /// @param _fundingPercentage The new funding percentage in basis points (2 decimal basis points, ie 90% is 9000)
    /// @dev This function can only be called by the contract owner
    function setFundingPercentage(uint256 _fundingPercentage) public onlyOwner {
        require(_fundingPercentage > 0 && _fundingPercentage <= 10000, "Invalid percentage");
        fundingPercentage = _fundingPercentage;
    }

    /// @notice Sets the grace period in days for determining if an invoice is impaired
    /// @param _days The number of days for the grace period
    /// @dev This function can only be called by the contract owner
    function setGracePeriodDays(uint256 _days) public onlyOwner {
        gracePeriodDays = _days;
    }

    /// @notice Sets the duration for which invoice approvals are valid
    /// @param _duration The new duration in seconds
    /// @dev This function can only be called by the contract owner
    function setApprovalDuration(uint256 _duration) public onlyOwner {
        approvalDuration = _duration;
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("Function not supported");
    }

    function mint(uint256, address) public pure override returns (uint256){
        revert("Function not supported");
    }
}