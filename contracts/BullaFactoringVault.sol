// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IFactoringVault.sol";

contract BullaFactoringVault is IBullaFactoringVault, Ownable {
    using SafeERC20 for IERC20;

    error NotFactoringFund(address);
    error ClaimAlreadyFunded(uint256);
    error ClaimNotFunded(uint256);
    error InvalidBps(uint16);

    IFactoringFund public factoringFund;
    IERC20 public underlyingAsset;

    /// @notice The amount of at risk capital for a given claim
    mapping(uint256 => uint256) private _atRiskCapitalByClaimId;

    /// @notice The total amount of capital at risk
    uint256 private _totalAtRiskCapital;

    constructor(address _owner, IERC20 _underlyingAsset, IFactoringFund _factoringFund) Ownable(_owner) {
        factoringFund = _factoringFund;
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
    function fundClaim(uint256 claimId, uint256 amount) external onlyFactoringFund {
        uint256 currentAtRiskCapitalForClaimId = _atRiskCapitalByClaimId[claimId];

        if (currentAtRiskCapitalForClaimId > 0) revert ClaimAlreadyFunded(claimId);
        
        IERC20(super.asset()).safeTransfer(msg.sender, amount);

        _atRiskCapitalByClaimId[claimId] = amount;
        _totalAtRiskCapital += amount;
    }

    /// @notice Helper function to handle the logic of repaying a claim
    /// @param claimId The ID of the claim to repay
    /// @param amount The amount of assets to repay
    function repayClaim(uint256 claimId, uint256 amount) external onlyFactoringFund {
        uint256 currentAtRiskCapitalForClaimId = _atRiskCapitalByClaimId[claimId];

        if (currentAtRiskCapitalForClaimId == 0) revert ClaimNotFunded(claimId);

        IERC20(super.asset()).safeTransferFrom(msg.sender, address(this), amount);

        _atRiskCapitalByClaimId[claimId] = 0;
        _totalAtRiskCapital -= currentAtRiskCapitalForClaimId;
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
    /// @param assets The amount of assets to deposit
    /// @param _owner The address who owns the assets
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
        return (uint256(bps).mulDiv(totalAssets(), 10000, Math.Rounding.Floor));
    }

    /// @notice Helper function to handle the logic of redeeming assets
    /// @param bps The basis points of the total vault value to redeem
    /// @param to The address to receive the assets
    /// @return The amount of assets to redeem
    function redeem(uint256 bps) public onlyOwner returns (uint256) {
        _redeemTo(_msgSender(), bps);
    }

    /// @notice Helper function to handle the logic of redeeming assets
    /// @param to The address to receive the assets
    /// @param bps The basis points to redeem
    /// @return The amount of assets to redeem
    function redeemTo(address to, uint256 bps) public onlyOwner returns (uint256) {
        _redeemTo(to, bps);
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

    //////////////////////////////////////////////////////
    //////////////// MODIFIERS ///////////////////////////
    //////////////////////////////////////////////////////

    modifier onlyFactoringFund() {
        if (_msgSender() != address(factoringFund)) revert NotFactoringFund(_msgSender());
        _;
    }
}
