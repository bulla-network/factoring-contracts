// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Invariant
// - The vault cannot lock up tokens.
// - The underlying asset is the asset used to fund the receivables, not the treasury asset
interface IBullaFactoringVault {
    // withdraws the underlying asset from the vault for a given claim
    function fundClaim(uint256 claimId, uint256 amount) external;
    // deposits the underlying asset into the vault for the given claim
    function repayClaim(uint256 claimId, uint256 amount) external;
    // returns the total assets in the vault
    function totalAssets() external view returns (uint256);
}

// Factoring fund interface from the perspective of the vault
interface IFactoringFund {
    // returns the underlying asset of the fund
    function underlyingAsset() external view returns (address);
    // returns the accrued interest for the vault (the msg.sender)
    function getAccruedInterestForVault() external view returns (uint256);
}