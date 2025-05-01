// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC4626.sol";
import "./interfaces/IFactoringVault.sol";

contract OwnedBullaFactoringVault is IOwnedBullaFactoringVault, Ownable, ERC4626 {
    using SafeERC20 for IERC20;

    address public factoringFund;
    address private _factoringUnderlyingAsset;

    constructor(address _factoringFund, address __factoringUnderlyingAsset) Ownable(_factoringFund) ERC4626(__factoringUnderlyingAsset) {
        factoringFund = _factoringFund;
        _factoringUnderlyingAsset = __factoringUnderlyingAsset;
    }

    /// @notice Returns the number of decimals the token uses, same as the underlying asset
    /// @return The number of decimals for this token
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC20(address(_factoringUnderlyingAsset)).decimals();
    }
    
    function factoringUnderlyingAsset() external view returns (address) {
        return _factoringUnderlyingAsset;
    }

    /// @notice Calculates the current price per share of the fund, 
    /// @return The current price per share, scaled to the underlying asset's decimal places
    function pricePerShare() public view returns (uint256) {
        return previewRedeem(10**decimals());
    }

    ////////////////////////////////////////////////////
    //////////////// DEPOSIT FUNCTIONS /////////////////
    ////////////////////////////////////////////////////
    
    /** @dev See {IERC4626-previewDeposit}. */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 capitalAccount = calculateCapitalAccount();
        uint256 sharesOutstanding = totalSupply();
        uint256 shares;

        if(sharesOutstanding == 0) {
            shares = assets;
        } else {
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

    /// @notice Allows for the deposit of assets in exchange for fund shares with an attachment
    /// @param assets The amount of assets to deposit
    /// @param receiver The address to receive the fund shares
    /// @param attachment The attachment data for the deposit
    /// @return The number of shares issued for the deposit
    function depositWithAttachment(uint256 assets, address receiver, Multihash calldata attachment) external returns (uint256) {
        uint256 shares = deposit(assets, receiver);
        emit DepositMadeWithAttachment(_msgSender(), assets, shares, attachment);
        return shares;
    }


    //////////////////////////////////////////////////////
    //////////////// CONVERSION FUNCTIONS ////////////////
    //////////////////////////////////////////////////////

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
}
