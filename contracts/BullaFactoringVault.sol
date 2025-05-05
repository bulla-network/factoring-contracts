// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IFactoringVault.sol";
import "./Permissions.sol";

contract BullaFactoringVault is ERC4626, IBullaFactoringVault, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error NotFactoringFund(address);
    error ClaimAlreadyFunded(uint256);
    error InvalidBps(uint16);
    error FundAlreadyAuthorized(address);
    error FundNotAuthorized(address);
    error NotFundRequester(address, uint256);
    error InvalidAmount(uint256);
    error UnauthorizedDeposit(address caller);

    /// @notice The decimals offset for the vault
    uint8 private __decimalsOffset;

    /// @notice The deposit permissions contract
    Permissions private depositPermissions;

    /// @notice Mapping of authorized factoring funds
    mapping(address => bool) public authorizedFactoringFunds;
    
    /// @notice Array to track all authorized factoring funds
    address[] private _authorizedFundsList;

    /// @notice The amount of locked shares by claim ID
    mapping(uint256 => uint256) private _lockedSharesByClaimId;

    /// @notice The fund requester for a given claim ID
    mapping(uint256 => address) private _fundRequesterByClaimId;

    /// @notice The total amount of locked shares per fund
    mapping(address => uint256) private _totalLockedSharesByFund;
    
    /// @notice The global total of locked shares across all funds
    uint256 private _totalLockedShares;

    /// @notice Event emitted when a factoring fund is authorized
    event FactoringFundAuthorized(address indexed fund);
    
    /// @notice Event emitted when a factoring fund is deauthorized
    event FactoringFundDeauthorized(address indexed fund);    

    constructor(address _owner, IERC20 _underlyingAsset, uint8 ___decimalsOffset, address _depositPermissions, string memory _name, string memory _symbol) ERC20(_name, _symbol ) ERC4626(_underlyingAsset) Ownable(_owner) {
        __decimalsOffset = ___decimalsOffset;
        depositPermissions = Permissions(_depositPermissions);
    }

    //////////////////////////////////////////////
    ////////// FACTORING VAULT FUNCTIONS /////////
    //////////////////////////////////////////////

    function calculateCapitalAccount() public view returns (uint256) {
        return previewRedeem(unlockedShareSupply());
    }

    /// @notice Helper function to handle the logic of funding a claim
    /// @param receiver The address to receive the assets
    /// @param claimId The ID of the claim to fund
    /// @param amount The amount of assets to fund
    function fundClaim(address receiver,uint256 claimId, uint256 amount) external onlyAuthorizedFactoringFund {
        address fund = _msgSender();
        uint256 currentLockedSharesForClaimId = _lockedSharesByClaimId[claimId];

        if (currentLockedSharesForClaimId > 0) revert ClaimAlreadyFunded(claimId);
        if (amount == 0) revert InvalidAmount(amount);
        
        // Calculate shares equivalent to the amount being funded
        uint256 sharesToLock = previewRedeem(amount);
        
        IERC20(asset()).safeTransfer(receiver, amount);

        _fundRequesterByClaimId[claimId] = fund;
        _lockedSharesByClaimId[claimId] = sharesToLock;
        _totalLockedSharesByFund[fund] += sharesToLock;
        _totalLockedShares += sharesToLock;
    }

    /// @notice Helper function to handle the logic of marking a claim as paid
    /// @notice the fund requester is responsible for sending the underlying asset to the vault
    /// @param claimId The ID of the claim to mark as paid
    function markClaimAsPaid(uint256 claimId) external {
        _unlockShares(claimId);

        // reset the fund requester to mark the claim as paid
        _fundRequesterByClaimId[claimId] = address(0);
    }

    /// @notice Helper function to handle the logic of marking a claim as impaired
    /// @notice this simply unlocks the shares for the claim
    /// @param claimId The ID of the claim to mark as impaired
    function markClaimAsImpaired(uint256 claimId) external {
        _unlockShares(claimId);
    }

    function _unlockShares(uint256 claimId) internal onlyFundRequester(claimId)   {
        address fund = _msgSender();
        uint256 currentLockedSharesForClaimId = _lockedSharesByClaimId[claimId];

        if (currentLockedSharesForClaimId != 0) {
            _lockedSharesByClaimId[claimId] = 0;
            _totalLockedSharesByFund[fund] -= currentLockedSharesForClaimId;
            _totalLockedShares -= currentLockedSharesForClaimId;
        }
    }

    /// @notice Returns the total amount of locked shares for a specific fund
    /// @param fund The address of the factoring fund
    /// @return The total amount of locked shares for the fund
    function totalLockedSharesByFund(address fund) external view returns (uint256) {
        return _totalLockedSharesByFund[fund];
    }
    
    /// @notice Returns the total amount of locked shares across all funds
    /// @return The global total of locked shares
    function getTotalLockedShares() external view returns (uint256) {
        return _totalLockedShares;
    }
    
    /// @notice Returns all authorized factoring funds
    /// @return Array of authorized factoring fund addresses
    function getAuthorizedFunds() external view returns (address[] memory) {
        return _authorizedFundsList;
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
    function totalAssets() public view override(ERC4626, IBullaFactoringVault) returns (uint256) {
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
        uint256 totalAccruedInterest = 0;
        for (uint256 i = 0; i < _authorizedFundsList.length; i++) {
            address fund = _authorizedFundsList[i];
            totalAccruedInterest += IFactoringFund(fund).getAccruedInterestForVault();
        }
        return assets.mulDiv(unlockedShareSupply()  + 10 ** _decimalsOffset(), totalAssets() + totalAccruedInterest + 1, Math.Rounding.Floor);
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

    //////////////////////////////////////
    /////////// OWNER FUNCTIONS //////////
    //////////////////////////////////////

    /// @notice Authorizes a factoring fund to use this vault
    /// @param fund The address of the factoring fund to authorize
    function authorizeFactoringFund(address fund) external onlyOwner {
        if (authorizedFactoringFunds[fund]) revert FundAlreadyAuthorized(fund);
        
        authorizedFactoringFunds[fund] = true;
        _authorizedFundsList.push(fund);
        
        emit FactoringFundAuthorized(fund);
    }
    
    /// @notice Deauthorizes a factoring fund from using this vault
    /// @param fund The address of the factoring fund to deauthorize
    function deauthorizeFactoringFund(address fund) external onlyOwner {
        if (!authorizedFactoringFunds[fund]) revert FundNotAuthorized(fund);
        
        authorizedFactoringFunds[fund] = false;
        
        // Remove from the list
        for (uint256 i = 0; i < _authorizedFundsList.length; i++) {
            if (_authorizedFundsList[i] == fund) {
                _authorizedFundsList[i] = _authorizedFundsList[_authorizedFundsList.length - 1];
                _authorizedFundsList.pop();
                break;
            }
        }
        
        emit FactoringFundDeauthorized(fund);
    }

    /// @notice Updates the deposit permissions contract
    /// @param _newDepositPermissionsAddress The new deposit permissions contract address
    function setDepositPermissions(address _newDepositPermissionsAddress) public onlyOwner {
        depositPermissions = Permissions(_newDepositPermissionsAddress);
        emit DepositPermissionsChanged(_newDepositPermissionsAddress);
    }

    ////////////////////////////////////////////
    //////////////// MODIFIERS /////////////////
    ////////////////////////////////////////////

    modifier onlyAuthorizedFactoringFund() {
        if (!authorizedFactoringFunds[_msgSender()]) revert NotFactoringFund(_msgSender());
        _;
    }

    modifier onlyFundRequester(uint256 claimId) {
        if (_fundRequesterByClaimId[claimId] != _msgSender()) revert NotFundRequester(_msgSender(), claimId);
        _;
    }
}
