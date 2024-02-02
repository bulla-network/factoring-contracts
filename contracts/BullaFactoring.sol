// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import {console} from "../lib/forge-std/src/console.sol";

/// @title Bulla Factoring Fund POC
/// @author @solidoracle
/// @notice  
contract BullaFactoring is ERC20, ERC4626, Ownable {
    using Math for uint256;

    IERC20 public assetAddress;
    uint256 public totalDeposits; // change to private in prod
    uint256 public totalWithdrawals; // change to private in prod
    uint256 public fundingPercentage = 9000; // 90% in bps

    uint256 public constant SCALING_FACTOR = 1000;
    uint256 public gracePeriodDays = 60;

    struct Invoice {
        uint256 faceValue;
        uint256 fundedAmount;
        uint256 paidAmount;
        bool isImpaired;
        address originalCreditor; 
        uint256 dueDate;
    }

    /// Mapping from invoice ID to Invoice struct
    mapping(uint256 => Invoice) public invoices;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => uint256) public paidInvoicesGain;

    /// Array to hold the IDs of all active invoices
    uint256[] public activeInvoices;

    // Array to track IDs of paid invoices
    uint256[] private paidInvoicesIds;

    /// @param _asset underlying supported stablecoin asset for deposit 
    constructor(IERC20 _asset) ERC20('Bulla Fund Token', 'BFT') ERC4626(_asset) Ownable(msg.sender) {
        assetAddress = _asset;
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20.decimals();
    }

    function pricePerShare() public view returns (uint256) {
        uint256 sharesOutstanding = totalSupply();
        if (sharesOutstanding == 0) {
            return SCALING_FACTOR;
        }
        uint256 capitalAccount = calculateCapitalAccount();
        return Math.mulDiv(capitalAccount, SCALING_FACTOR, sharesOutstanding);
    }

    function calculateRealizedGainLoss() private view returns (uint256) {
        uint256 realizedGains = 0;
        // Consider gains from paid invoices
        for (uint256 i = 0; i < paidInvoicesIds.length; i++) {
            uint256 invoiceId = paidInvoicesIds[i];
            realizedGains += paidInvoicesGain[invoiceId];
        }
        // Consider impaired invoices from activeInvoices
        // to be calculated after gains
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            Invoice storage invoice = invoices[activeInvoices[i]];
            if (isInvoiceImpaired(activeInvoices[i])) {
                realizedGains -= uint256(invoice.fundedAmount);
            }
        }
        return realizedGains;
    }

    function calculateCapitalAccount() public view returns (uint256) {
        uint256 realizedGainLoss = calculateRealizedGainLoss();
        uint256 capitalAccount = totalDeposits - totalWithdrawals + realizedGainLoss;
        return uint256(capitalAccount);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 currentPricePerShare = pricePerShare();
        return Math.mulDiv(assets, SCALING_FACTOR, currentPricePerShare);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = convertToShares(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        
        totalDeposits += assets;

        return shares;
    }

    function fundInvoice(uint256 invoiceId, uint256 faceValue, uint256 dueDate) public {
        uint256 fundedAmount = Math.mulDiv(faceValue, fundingPercentage, 10000);
        invoices[invoiceId] = Invoice(faceValue, fundedAmount, 0, false, msg.sender, dueDate);
        assetAddress.transfer(msg.sender, fundedAmount);
        activeInvoices.push(invoiceId);
    }

    function payInvoice(uint256 invoiceId) public {
        Invoice storage invoice = invoices[invoiceId];
        require(invoice.paidAmount < invoice.faceValue, "Invoice already paid");
        assetAddress.transferFrom(msg.sender, address(this), invoice.faceValue);
        invoice.paidAmount = invoice.faceValue; 

        // Calculate gain/loss and store in the new mapping
        uint256 factoringGain = invoice.faceValue - invoice.fundedAmount;
        paidInvoicesGain[invoiceId] = uint256(factoringGain);

        // Add invoiceId to paidInvoicesIds for tracking
        paidInvoicesIds.push(invoiceId);

        // Remove the invoice ID from the activeInvoices array
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            if (activeInvoices[i] == invoiceId) {
                activeInvoices[i] = activeInvoices[activeInvoices.length - 1];
                activeInvoices.pop();
                break;
            }
        }
    }

    function isInvoiceImpaired(uint256 invoiceId) public view returns (bool) {
        Invoice storage invoice = invoices[invoiceId];
        uint256 DaysAfterDueDate = invoice.dueDate + (gracePeriodDays * 1 days); 
        
        return block.timestamp > DaysAfterDueDate;
    }

    function setGracePeriodDays(uint256 _days) public onlyOwner {
        gracePeriodDays = _days;
    }

    function maxRedeem() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        uint256 currentPricePerShare = pricePerShare();
        // Calculate the maximum withdrawable shares based on total assets and current price per share
        uint256 maxWithdrawableShares = Math.mulDiv(totalAssetsInFund, 1e18, currentPricePerShare);
        return maxWithdrawableShares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 maxWithdrawableShares = maxRedeem();
        uint256 assets;
        if (shares > maxWithdrawableShares) {
            uint256 maxWithdrawableAmount = totalAssets();   
            _withdraw(_msgSender(), receiver, owner, maxWithdrawableAmount, maxWithdrawableShares);
            assets = Math.mulDiv(maxWithdrawableShares, pricePerShare(), SCALING_FACTOR);
        } else {
            uint256 currentPricePerShare = pricePerShare();
            console.log("currentPricePerShare:");
            console.logUint(currentPricePerShare);

            assets = Math.mulDiv(shares, currentPricePerShare, SCALING_FACTOR);
     
            _withdraw(_msgSender(), receiver, owner, assets, shares);
        }
        totalWithdrawals += assets;
        return assets;
    }

    function setFundingPercentage(uint256 _fundingPercentage) public onlyOwner {
        require(_fundingPercentage > 0 && _fundingPercentage <= 10000, "Invalid percentage");
        fundingPercentage = _fundingPercentage;
    }
}