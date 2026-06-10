// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for Aave's GHO token, restricted to the functions a facilitator needs.
/// @dev Mirrors https://github.com/aave/gho-core GhoToken. A facilitator may mint GHO up to its
///      bucket capacity and burn GHO it holds to reduce its bucket level.
interface IGhoToken is IERC20 {
    /// @notice Mints GHO to an account, increasing the calling facilitator's bucket level
    /// @dev Only callable by an approved facilitator, up to its bucket capacity
    function mint(address account, uint256 amount) external;

    /// @notice Burns GHO from the caller's balance, decreasing the calling facilitator's bucket level
    function burn(uint256 amount) external;

    /// @notice Returns the bucket configuration of a facilitator
    /// @return capacity The maximum GHO the facilitator is allowed to have outstanding
    /// @return level The GHO currently minted and outstanding by the facilitator
    function getFacilitatorBucket(address facilitator) external view returns (uint256 capacity, uint256 level);
}
