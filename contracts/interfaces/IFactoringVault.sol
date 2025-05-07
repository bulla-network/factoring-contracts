// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

// Invariant
// - The vault cannot lock up tokens.
// - The underlying asset is the asset used to fund the receivables, not the treasury asset

interface IBullaFactoringVault {
    struct Multihash {
        bytes32 hash;
        uint8 hashFunction;
        uint8 size;
    }

    event DepositMadeWithAttachment(address indexed depositor, uint256 assets, uint256 shares, Multihash attachment);
    event SharesRedeemedWithAttachment(address indexed redeemer, uint256 shares, uint256 assets, Multihash attachment);
    event DepositPermissionsChanged(address newAddress);

    // withdraws the underlying asset from the vault for a given claim
    function fundClaim(address receiver, uint256 claimId, uint256 amount) external;
    // marks a claim as paid
    function markClaimAsPaid(uint256 claimId) external;
    // marks a claim as impaired
    function markClaimAsImpaired(uint256 claimId) external;
    // returns the total assets in the vault
    function totalAssets() external view returns (uint256);
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
    function underlyingAsset() external view returns (IERC20);
    // returns the accrued interest for the vault (the msg.sender)
    function getAccruedInterestForVault() external view returns (uint256);
    // returns the list of paid invoices and the list of impaired invoices
    function viewPoolStatus() external view returns (uint256[] memory, uint256[] memory);
}