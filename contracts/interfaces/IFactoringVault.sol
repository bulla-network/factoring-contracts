// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// Invariant
// - The vault cannot lock up tokens.

// OwnedBullaFactoringVault is a vault that is owned by a factoring fund.
interface IOwnedBullaFactoringVault {
    // returns the underlying ERC20 asset of the vault
    function factoringUnderlyingAsset() external view returns (address);
    // withdraws the underlying asset from the vault for a given claim
    function fundClaim(uint256 claimId, uint256 amount) external;
    // deposits the underlying asset into the vault for the given claim
    function repayClaim(uint256 claimId, uint256 amount) external;
    // returns the maximum amount of underlying asset that can be withdrawn by the factoring fund
    function maxFundableClaim() external view returns (uint256);
}

interface IOwnedBullaFactoringVaultFactory {
    // creates a new vault for the msg.sender (the factoring fund)
    function createVault(address factoringUnderlyingAsset) external returns (IOwnedBullaFactoringVault);
}
