// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IFactoringVault.sol";

contract OwnedBullaFactoringVault is IOwnedBullaFactoringVault, Ownable, ERC4626 {
    using SafeERC20 for IERC20;

    error NotFactoringFund(address);
    error ClaimAlreadyFunded(uint256);
    error ClaimNotFunded(uint256);

    IFactoringFund public factoringFund;
    uint8 private __decimalsOffset;

    /// @notice Permissions contract for deposit and withdrawals
    Permissions public depositPermissions;

    /// @notice Total shares that are locked in the vault by the factoring fund
    mapping(uint256 => uint256) private _lockedSharesByClaimId;

    /// @notice Total number of shares locked from redemption
    uint256 private _totalLockedShares;

    constructor(IFactoringFund _factoringFund, address _depositPermissions, string memory _tokenName, string memory _tokenSymbol, uint8 ___decimalsOffset) ERC20(_tokenName, _tokenSymbol)  Ownable(_factoringFund) ERC4626(_factoringFund.underlyingAsset()) {
        factoringFund = _factoringFund;
        depositPermissions = Permissions(_depositPermissions);
        __decimalsOffset = ___decimalsOffset;
    }

    //////////////////////////////////////////////
    ////////// FACTORING VAULT FUNCTIONS /////////
    //////////////////////////////////////////////

    function fundClaim(uint256 claimId, uint256 amount) external onlyFactoringFund {
        uint256 currentSharesForClaimId = _lockedSharesByClaimId[claimId];

        if (currentSharesForClaimId > 0) revert ClaimAlreadyFunded(claimId);
        
        IERC20(super.asset()).safeTransfer(msg.sender, amount);
        
        uint256 shares = previewRedeem(amount);

        _lockedSharesByClaimId[claimId] = shares;
        _totalLockedShares += shares;
    }

    function repayClaim(uint256 claimId, uint256 amount) external onlyFactoringFund {
        uint256 sharesLocked = _lockedSharesByClaimId[claimId];

        if (sharesLocked == 0) revert ClaimNotFunded(claimId);

        IERC20(super.asset()).safeTransferFrom(msg.sender, address(this), amount);

        _lockedSharesByClaimId[claimId] = 0;
        _totalLockedShares -= sharesLocked;
    }

    function unlockedShareSupply() public view returns (uint256) {
        return totalSupply() - _totalLockedShares;
    }

    //////////////////////////////////////////////
    ////////// ERC4626 ACCOUNTING FUNCTIONS //////
    //////////////////////////////////////////////

    /// @notice Returns the total assets of the vault
    /// @dev TODO: Will have to calculate the swap value of treasury assets to underlying asset
    /// @return The total assets of the vault
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets();
    }

    /* see ERC4626.sol */
    function _decimalsOffset() internal view override returns (uint8) {
        return __decimalsOffset;
    }

    ////////////////////////////////////////////////////
    //////////////// DEPOSIT FUNCTIONS /////////////////
    ////////////////////////////////////////////////////
    
    /** @dev See {IERC4626-previewDeposit}.
     *  @dev override to account for accrued interest that is not yet reflected in the total assets
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return assets.mulDiv(unlockedShareSupply()  + 10 ** _decimalsOffset(), totalAssets() + factoringFund.getAccruedInterestForVault() + 1, Math.Rounding.Floor);
    }

    /// @notice Helper function to handle the logic of depositing assets in exchange for fund shares
    /// @param receiver The address to receive the fund shares
    /// @param assets The amount of assets to deposit
    /// @return The number of shares issued for the deposit
    function deposit(uint256 assets,address receiver) public override returns (uint256) {
        if (!depositPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        
        return super.deposit(assets, receiver);
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
    //////////////// REDEEM FUNCTIONS ////////////////////
    //////////////////////////////////////////////////////
    
    /// @notice Helper function to handle the logic of redeeming shares in exchange for assets
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the assets
    /// @param _owner The owner of the shares being redeemed
    /// @return The number of shares redeemed
    function redeem(uint256 shares, address receiver, address _owner) public override returns (uint256) {
        if (!depositPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!depositPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);
        
        return super.redeem(shares, receiver, _owner);
    }

    /// @notice Redeems shares for underlying assets with an attachment, transferring the assets to the specified receiver
    /// @param shares The number of shares to redeem
    /// @param receiver The address to receive the redeemed assets
    /// @param _owner The owner of the shares being redeemed
    /// @param attachment The attachment data for the redemption
    /// @return The amount of assets redeemed
    function redeemWithAttachment(uint256 shares, address receiver, address _owner, Multihash calldata attachment) external returns (uint256) {
        uint256 assets = redeem(shares, receiver, _owner);
        emit SharesRedeemedWithAttachment(_msgSender(), shares, assets, attachment);
        return assets;
    }

    /// @notice Calculates the maximum amount of shares that can be redeemed based on the total assets in the fund
    /// @param _owner The owner of the shares being redeemed
    /// @return The maximum number of shares that can be redeemed
    function maxRedeem(address _owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(_owner), unlockedShareSupply());
    }

    //////////////////////////////////////////////////////
    //////////////// WITHDRAW FUNCTIONS //////////////////
    //////////////////////////////////////////////////////

    /// @notice Helper function to handle the logic of withdrawing assets in exchange for fund shares
    /// @param receiver The address to receive the assets
    /// @param _owner The address who owns the shares to redeem
    /// @param assets The amount of assets to withdraw
    /// @return The number of shares redeemed
    function withdraw(uint256 assets, address receiver, address _owner) public override returns (uint256) {
        if (!depositPermissions.isAllowed(_msgSender())) revert UnauthorizedDeposit(_msgSender());
        if (!depositPermissions.isAllowed(_owner)) revert UnauthorizedDeposit(_owner);
 
        return super.withdraw(assets, receiver, _owner);
    }

    //////////////////////////////////////////////////////
    //////////////// CONVERSION FUNCTIONS ////////////////
    //////////////////////////////////////////////////////

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     * @dev override to account for locked shares
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(unlockedShareSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     * @dev override to account for locked shares
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, unlockedShareSupply() + 10 ** _decimalsOffset(), rounding);
    }

    //////////////////////////////////////////////////////
    //////////////// OWNER FUNCTIONS /////////////////////
    //////////////////////////////////////////////////////

    /// @notice Updates the deposit permissions contract
    /// @param _newDepositPermissionsAddress The new deposit permissions contract address
    function setDepositPermissions(address _newDepositPermissionsAddress) public onlyOwner {
        depositPermissions = Permissions(_newDepositPermissionsAddress);
        emit DepositPermissionsChanged(_newDepositPermissionsAddress);
    }

    //////////////////////////////////////////////////////
    //////////////// MODIFIERS ///////////////////////////
    //////////////////////////////////////////////////////

    modifier onlyFactoringFund() {
        if (_msgSender() != address(factoringFund)) revert NotFactoringFund(_msgSender());
        _;
    }
}
