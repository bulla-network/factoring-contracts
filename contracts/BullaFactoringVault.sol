// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IFactoringVault.sol";

contract BullaFactoringVault is IBullaFactoringVault, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error NotFactoringFund(address);
    error ClaimAlreadyFunded(uint256);
    error InvalidBps(uint16);
    error FundAlreadyAuthorized(address);
    error FundNotAuthorized(address);
    error NotFundRequester(address, uint256);
    error InvalidAmount(uint256);

    /// @notice Mapping of authorized factoring funds
    mapping(address => bool) public authorizedFactoringFunds;
    
    /// @notice Array to track all authorized factoring funds
    address[] private _authorizedFundsList;
    
    IERC20 public underlyingAsset;

    /// @notice The amount of at risk capital by claim ID
    mapping(uint256 => uint256) private _atRiskCapitalByClaimId;

    /// @notice The fund requester for a given claim ID
    mapping(uint256 => address) private _fundRequesterByClaimId;

    /// @notice The total amount of capital at risk per fund
    mapping(address => uint256) private _totalAtRiskCapitalByFund;
    
    /// @notice The global total of at risk capital across all funds
    uint256 private _globalTotalAtRiskCapital;

    /// @notice Event emitted when a factoring fund is authorized
    event FactoringFundAuthorized(address indexed fund);
    
    /// @notice Event emitted when a factoring fund is deauthorized
    event FactoringFundDeauthorized(address indexed fund);

    constructor(address _owner, IERC20 _underlyingAsset) Ownable(_owner) {
        underlyingAsset = _underlyingAsset;
    }

    //////////////////////////////////////////////
    ////////// FACTORING VAULT FUNCTIONS /////////
    //////////////////////////////////////////////

    /// @notice Returns the total assets in the vault
    /// @return The total assets in the vault
    function totalAssets() external view returns (uint256) {
        return underlyingAsset.balanceOf(address(this));
    }

    /// @notice Helper function to handle the logic of funding a claim
    /// @param claimId The ID of the claim to fund
    /// @param amount The amount of assets to fund
    function fundClaim(uint256 claimId, uint256 amount) external onlyAuthorizedFactoringFund {
        address fund = _msgSender();
        uint256 currentAtRiskCapitalForClaimId = _atRiskCapitalByClaimId[claimId];

        if (currentAtRiskCapitalForClaimId > 0) revert ClaimAlreadyFunded(claimId);
        if (amount == 0) revert InvalidAmount(amount);
        
        underlyingAsset.safeTransfer(fund, amount);

        _fundRequesterByClaimId[claimId] = fund;
        _atRiskCapitalByClaimId[claimId] = amount;
        _totalAtRiskCapitalByFund[fund] += amount;
        _globalTotalAtRiskCapital += amount;
    }

    /// @notice Helper function to handle the logic of marking a claim as paid
    /// @notice the fund requester is responsible for sending the underlying asset to the vault
    /// @param claimId The ID of the claim to mark as paid
    function markClaimAsPaid(uint256 claimId) external onlyFundRequester(claimId) {
        address fund = _msgSender();
        uint256 currentAtRiskCapitalForClaimId = _atRiskCapitalByClaimId[claimId];

        _fundRequesterByClaimId[claimId] = address(0);
        _atRiskCapitalByClaimId[claimId] = 0;
        _totalAtRiskCapitalByFund[fund] -= currentAtRiskCapitalForClaimId;
        _globalTotalAtRiskCapital -= currentAtRiskCapitalForClaimId;
    }

    /// @notice Returns the total amount of at-risk capital for a specific fund
    /// @param fund The address of the factoring fund
    /// @return The total amount of at-risk capital for the fund
    function totalAtRiskCapitalByFund(address fund) external view returns (uint256) {
        return _totalAtRiskCapitalByFund[fund];
    }
    
    /// @notice Returns the total amount of at-risk capital across all funds
    /// @return The global total of at-risk capital
    function globalTotalAtRiskCapital() external view returns (uint256) {
        return _globalTotalAtRiskCapital;
    }
    
    /// @notice Returns all authorized factoring funds
    /// @return Array of authorized factoring fund addresses
    function getAuthorizedFunds() external view returns (address[] memory) {
        return _authorizedFundsList;
    }    

    ////////////////////////////////////////////////////
    //////////////// DEPOSIT FUNCTIONS /////////////////
    ////////////////////////////////////////////////////

    /// @notice Helper function to handle the logic of depositing assets
    /// @param assets The amount of assets to deposit
    function deposit(uint256 assets) public onlyOwner {
        _depositFrom(_msgSender(), assets);
    }

    /// @notice Helper function to handle the logic of depositing assets
    /// @param from The address who owns the assets
    /// @param assets The amount of assets to deposit
    function depositFrom(address from, uint256 assets) public onlyOwner {
        _depositFrom(from, assets);
    }

    function _depositFrom(address from, uint256 assets) internal {
        underlyingAsset.safeTransferFrom(from, address(this), assets);
    }

    //////////////////////////////////////////////////////
    //////////////// REDEEM FUNCTIONS ////////////////////
    //////////////////////////////////////////////////////

    /// @notice Helper function to handle the logic of redeeming assets
    /// @param bps The basis points of the total vault value to redeem
    /// @return The amount of assets to redeem
    function previewRedeem(uint256 bps) public view returns (uint256) {
        return (bps * underlyingAsset.balanceOf(address(this))) / 10000;
    }

    /// @notice Helper function to handle the logic of redeeming assets
    /// @param bps The basis points of the total vault value to redeem
    /// @return The amount of assets redeemed
    function redeem(uint256 bps) public onlyOwner returns (uint256) {
        return _redeemTo(_msgSender(), bps);
    }

    /// @notice Helper function to handle the logic of redeeming assets
    /// @param to The address to receive the assets
    /// @param bps The basis points to redeem
    /// @return The amount of assets redeemed
    function redeemTo(address to, uint256 bps) public onlyOwner returns (uint256) {
        return _redeemTo(to, bps);
    }

    function _redeemTo(address to, uint16 bps) internal returns (uint256) {
        if (bps > 10000 || bps == 0) revert InvalidBps(bps);

        uint256 assets = previewRedeem(bps);
        underlyingAsset.safeTransfer(to, assets);

        return assets;
    }

    //////////////////////////////////////////////////////
    //////////////// WITHDRAW FUNCTIONS //////////////////
    //////////////////////////////////////////////////////

    /// @notice Helper function to handle the logic of withdrawing assets
    /// @param assets The amount of assets to withdraw
    function withdraw(uint256 assets) public onlyOwner {
        _withdrawTo(_msgSender(), assets);
    }

    /// @notice Helper function to handle the logic of withdrawing assets
    /// @param to The address to receive the assets
    /// @param assets The amount of assets to withdraw
    function withdrawTo(address to, uint256 assets) public onlyOwner {
        _withdrawTo(to, assets);
    }

    /// @notice Helper function to handle the logic of withdrawing assets
    /// @param to The address to receive the assets
    /// @param assets The amount of assets to withdraw
    function _withdrawTo(address to, uint256 assets) internal {
        underlyingAsset.safeTransfer(to, assets);
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
