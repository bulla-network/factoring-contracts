// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/utils/Multihash.sol";
// Invariant
// - The vault cannot lock up tokens.
// - The vault must be controlled by the factoring fund
// - The underlying asset is the asset used to fund the receivables, not the treasury asset

// OwnedBullaFactoringVault is a vault that is owned by a factoring fund.
interface IBullaFactoringVault is IERC4626 {
    event DepositMadeWithAttachment(address indexed depositor, uint256 assets, uint256 shares, Multihash attachment);
    event SharesRedeemedWithAttachment(address indexed redeemer, uint256 shares, uint256 assets, Multihash attachment);

    // withdraws the underlying asset from the vault for a given claim
    function fundClaim(address receiver, uint256 claimId, uint256 amount) external;
    // marks a claim as paid
    function markClaimAsPaid(uint256 claimId) external;
    // marks a claim as impaired
    function markClaimAsImpaired(uint256 claimId) external;
    // returns the total assets in the vault
    function totalAssets() external view returns (uint256);
    // returns the total at risk capital for a given fund
    function totalAtRiskCapitalByFund(address fund) external view returns (uint256);
    // returns the total at risk capital across all funds
    function globalTotalAtRiskCapital() external view returns (uint256);
    // returns all authorized factoring funds
    function getAuthorizedFunds() external view returns (address[] memory);
}

interface IBullaFactoringVaultFactory {
    // creates a new vault for the msg.sender (the factoring fund)
    function createVault(address underlyingAsset, address depositPermissions) external returns (IBullaFactoringVault);
}

// Factoring fund interface from the perspective of the vault
interface IFactoringFund {
    // returns the underlying asset of the fund
    function underlyingAsset() external view returns (address);
    // returns the accrued interest for the vault (the msg.sender)
    function getAccruedInterestForVault() external view returns (uint256);
}