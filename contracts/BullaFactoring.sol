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
    uint256 public totalDeposits; // change to private
    uint256 public totalWithdrawals; // change to private

    struct Invoice {
        uint256 faceValue;
        uint256 fundedAmount;
        bool isPaid;
        bool isImpaired;
        address owner; 
    }

    /// Mapping from invoice ID to Invoice struct
    mapping(uint256 => Invoice) public invoices;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => int256) public paidInvoicesGainLoss;

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
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 sharesOutstanding = totalSupply();
        if (sharesOutstanding == 0) {
            return 1e18; 
        }
        return Math.mulDiv(capitalAccount, 1e18, sharesOutstanding);
    }

    function calculateRealizedGainLoss() private view returns (int256) {
        int256 realizedGains = 0;
        // Consider impaired invoices from activeInvoices
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            Invoice storage invoice = invoices[activeInvoices[i]];
            if (invoice.isImpaired) {
                realizedGains -= int256(invoice.fundedAmount);
            }
        }
        // Consider gains/losses from paid invoices
        for (uint256 i = 0; i < paidInvoicesIds.length; i++) {
            uint256 invoiceId = paidInvoicesIds[i];
            realizedGains += paidInvoicesGainLoss[invoiceId];
        }
        return realizedGains;
    }

    function calculateCapitalAccount() public view returns (uint256) {
        int256 realizedGainLoss = calculateRealizedGainLoss();
        int256 capitalAccount = int256(totalDeposits) - int256(totalWithdrawals) + realizedGainLoss;
        return uint256(capitalAccount);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 currentPricePerShare = pricePerShare();
        return Math.mulDiv(assets, 1e18, currentPricePerShare);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = convertToShares(assets);
        _deposit(_msgSender(), receiver, assets, shares);
        
        totalDeposits += assets;

        return shares;
    }

    function fundInvoice(uint256 invoiceId, uint256 faceValue) public {
        uint256 fundedAmount = Math.mulDiv(faceValue, 90, 100);
        invoices[invoiceId] = Invoice(faceValue, fundedAmount, false, false, msg.sender);
        assetAddress.transfer(msg.sender, fundedAmount);
        activeInvoices.push(invoiceId);
    }

    function payInvoice(uint256 invoiceId) public {
        Invoice storage invoice = invoices[invoiceId];
        require(!invoice.isPaid, "Invoice already paid");
        assetAddress.transferFrom(msg.sender, address(this), invoice.faceValue);
        invoice.isPaid = true;

        // Calculate gain/loss and store in the new mapping
        uint256 factoringGain = invoice.faceValue - invoice.fundedAmount;
        paidInvoicesGainLoss[invoiceId] = int(factoringGain);

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

    // Function to declare an invoice as impaired
    function declareInvoiceImpaired(uint256 invoiceId) public onlyOwner {
        Invoice storage invoice = invoices[invoiceId];
        require(!invoice.isPaid, "Invoice already paid");
        require(!invoice.isImpaired, "Invoice already impaired");

        invoice.isImpaired = true;
    }

    function maxRedeem() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        uint256 currentPricePerShare = pricePerShare();
        // Calculate the maximum withdrawable shares based on total assets and current price per share
        uint256 maxWithdrawableShares = Math.mulDiv(totalAssetsInFund, 1e18, currentPricePerShare);
        return maxWithdrawableShares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 maxWithdrawableShares = maxRedeem(owner);
        uint256 assets;
        if (shares > maxWithdrawableShares) {            
            _withdraw(_msgSender(), receiver, owner, totalAssets(), maxWithdrawableShares);
            assets = Math.mulDiv(maxWithdrawableShares, pricePerShare(), 1e18);
            totalWithdrawals += assets; 
        } else {
            uint256 currentPricePerShare = pricePerShare();
            console.log("currentPricePerShare:");
            console.logUint(currentPricePerShare);

            assets = Math.mulDiv(shares, currentPricePerShare, 1e18);
     
            _withdraw(_msgSender(), receiver, owner, assets, shares);
            totalWithdrawals += assets;
        }
        return assets;
    }
}