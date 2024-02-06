// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import {console} from "../lib/forge-std/src/console.sol";
import "./interfaces/IInvoice.sol";

/// @title Bulla Factoring Fund POC
/// @author @solidoracle
/// @notice  
contract BullaFactoring is ERC20, ERC4626, Ownable {
    using Math for uint256;

    IERC20 public assetAddress;
    uint256 public totalDeposits; // change to private in prod
    uint256 public totalWithdrawals; // change to private in prod
    uint256 public fundingPercentage = 9000; // 90% in bps

    uint256 public SCALING_FACTOR;
    uint256 public gracePeriodDays = 60;

    struct FundedInvoiceDetails {
        IInvoice contractAddress;
        address originalCreditor; // is this used anywhere? maybe in the underwriter checks
        uint256 fundedAmount; // is this used anywhere? maybe in the underwriter checks
    }

    /// Mapping from invoice ID to FundedInvoiceDetails struct
    mapping(uint256 => FundedInvoiceDetails) public invoices;

    /// Mapping of paid invoices ID to track gains/losses
    mapping(uint256 => uint256) public paidInvoicesGain;

    /// Array to hold the IDs of all active invoices
    uint256[] public activeInvoices;

    // Array to track IDs of paid invoices
    uint256[] private paidInvoicesIds;

    /// @param _asset underlying supported stablecoin asset for deposit 
    constructor(IERC20 _asset) ERC20('Bulla Fund Token', 'BFT') ERC4626(_asset) Ownable(msg.sender) {
        assetAddress = _asset;
        SCALING_FACTOR = 10**uint256(ERC20(address(assetAddress)).decimals());
    }

    /// @notice same decimals as the underlying asset
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(assetAddress)).decimals();
    }

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
            FundedInvoiceDetails storage invoiceDetail = invoices[invoiceId];
            if (isInvoiceImpaired(invoiceId, invoiceDetail.contractAddress)) {
                realizedGains -= uint256(invoiceDetail.fundedAmount);
            }
        }
        return realizedGains;
    }

    function calculateCapitalAccount() public view returns (uint256) {
        uint256 realizedGainLoss = calculateRealizedGainLoss();
        uint256 capitalAccount = totalDeposits - totalWithdrawals + realizedGainLoss;
        return capitalAccount;
    }

    function pricePerShare() public view returns (uint256) {
        uint256 sharesOutstanding = totalSupply();
        if (sharesOutstanding == 0) {
            return SCALING_FACTOR;
        }
        uint256 capitalAccount = calculateCapitalAccount();
        return Math.mulDiv(capitalAccount, SCALING_FACTOR, sharesOutstanding);
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

    function fundInvoices(uint256[] memory invoiceIds, IInvoice invoiceContract) public {
        IInvoice.Invoice[] memory externalInvoices = invoiceContract.getInvoiceDetails(invoiceIds);
    
        for (uint i = 0; i < externalInvoices.length; i++) {
            // TODO: underwriter checks

            uint256 faceValue = externalInvoices[i].faceValue;
            uint256 fundedAmount = Math.mulDiv(faceValue, fundingPercentage, 10000);
            assetAddress.transfer(msg.sender, fundedAmount);
            invoices[invoiceIds[i]] = FundedInvoiceDetails(invoiceContract, msg.sender, fundedAmount);
            activeInvoices.push(invoiceIds[i]);
        }
    }

    function viewPoolStatus() public view returns (uint256[] memory paidInvoices, uint256[] memory impairedInvoices) {
        uint256 activeCount = activeInvoices.length;
        uint256[] memory tempPaidInvoices = new uint256[](activeCount);
        uint256[] memory tempImpairedInvoices = new uint256[](activeCount);
        uint256 paidCount = 0;
        uint256 impairedCount = 0;

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 invoiceId = activeInvoices[i];
            FundedInvoiceDetails storage invoice = invoices[invoiceId];
 
            if (isInvoicePaid(invoiceId, invoice.contractAddress)) {
                tempPaidInvoices[paidCount] = invoiceId;
                paidCount++;
            } else if (isInvoiceImpaired(invoiceId, invoice.contractAddress)) {
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

    function isInvoicePaid(uint256 invoiceId, IInvoice invoiceContract) private view returns (bool) {
        uint256[] memory invoiceIds = new uint256[](1);
        invoiceIds[0] = invoiceId;

        IInvoice.Invoice[] memory invoicesDetails = invoiceContract.getInvoiceDetails(invoiceIds);

        if (invoicesDetails.length > 0 && invoicesDetails[0].faceValue == invoicesDetails[0].paidAmount) {
            return true;
        } else {
            return false;
        }
    }

    function isInvoiceImpaired(uint256 invoiceId, IInvoice invoiceContract) private view returns (bool) {
        uint256[] memory invoiceIds = new uint256[](1);
        invoiceIds[0] = invoiceId;

        IInvoice.Invoice[] memory invoicesDetails = invoiceContract.getInvoiceDetails(invoiceIds);

        uint256 DaysAfterDueDate = invoicesDetails[0].dueDate + (gracePeriodDays * 1 days); 
        return block.timestamp > DaysAfterDueDate;
    }

    function reconcileActivePaidInvoices() public onlyOwner {
        (uint256[] memory paidInvoiceIds, ) = viewPoolStatus();

        for (uint256 i = 0; i < paidInvoiceIds.length; i++) {
            uint256 invoiceId = paidInvoiceIds[i];
            FundedInvoiceDetails storage invoice = invoices[invoiceId];

            // Retrieve the faceValue for the invoice from the external contract
            uint256[] memory invoiceIds = new uint256[](1);
            invoiceIds[0] = invoiceId;
            IInvoice.Invoice[] memory externalInvoices = invoice.contractAddress.getInvoiceDetails(invoiceIds);
            uint256 faceValue = externalInvoices[0].faceValue;

            // Calculate and store the factoring gain
            uint256 factoringGain = faceValue - invoice.fundedAmount;
            paidInvoicesGain[invoiceId] = factoringGain;

            // Add the invoice ID to the paidInvoicesIds array
            paidInvoicesIds.push(invoiceId);

            // Remove the invoice from activeInvoices array
            removeActivePaidInvoice(invoiceId);
        }
    }

    function removeActivePaidInvoice(uint256 invoiceId) private {
        for (uint256 i = 0; i < activeInvoices.length; i++) {
            if (activeInvoices[i] == invoiceId) {
                activeInvoices[i] = activeInvoices[activeInvoices.length - 1];
                activeInvoices.pop();
                break;
            }
        }
    }

    function maxRedeem() public view returns (uint256) {
        uint256 totalAssetsInFund = totalAssets();
        uint256 currentPricePerShare = pricePerShare();
        // Calculate the maximum withdrawable shares based on total assets and current price per share
        uint256 maxWithdrawableShares = Math.mulDiv(totalAssetsInFund, SCALING_FACTOR, currentPricePerShare);
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
            assets = Math.mulDiv(shares, currentPricePerShare, SCALING_FACTOR);
            _withdraw(_msgSender(), receiver, owner, assets, shares);
        }
        totalWithdrawals += assets;
        return assets;
    }

    /// @notice 2 decimal basis points, ie 90% is 9000
    function setFundingPercentage(uint256 _fundingPercentage) public onlyOwner {
        require(_fundingPercentage > 0 && _fundingPercentage <= 10000, "Invalid percentage");
        fundingPercentage = _fundingPercentage;
    }

    function setGracePeriodDays(uint256 _days) public onlyOwner {
        gracePeriodDays = _days;
    }
}