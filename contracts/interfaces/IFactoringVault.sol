// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Invariant
// - The vault cannot lock up tokens.
// - The underlying asset is the asset used to fund the receivables, not the treasury asset
interface IBullaFactoringVault {
    // withdraws the underlying asset from the vault for a given claim
    function fundClaim(uint256 claimId, uint256 amount) external;
    // marks a claim as paid
    function markClaimAsPaid(uint256 claimId) external;
    // returns the total assets in the vault
    function totalAssets() external view returns (uint256);
    // returns the total at risk capital for a given fund
    function totalAtRiskCapitalByFund(address fund) external view returns (uint256);
    // returns the total at risk capital across all funds
    function globalTotalAtRiskCapital() external view returns (uint256);
    // returns all authorized factoring funds
    function getAuthorizedFunds() external view returns (address[] memory);
}