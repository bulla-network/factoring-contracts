//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test double for Aave's GhoToken implementing facilitator bucket semantics:
///         only registered facilitators can mint (up to their bucket capacity), and
///         burning reduces the calling facilitator's bucket level.
contract MockGhoToken is ERC20 {
    struct Facilitator {
        uint128 bucketCapacity;
        uint128 bucketLevel;
    }

    mapping(address => Facilitator) private _facilitators;

    error NotFacilitator(address caller);
    error FacilitatorBucketCapacityExceeded();

    constructor() ERC20("Gho Token", "GHO") {}

    function addFacilitator(address facilitator, uint128 bucketCapacity) external {
        _facilitators[facilitator].bucketCapacity = bucketCapacity;
    }

    function mint(address account, uint256 amount) external {
        Facilitator storage f = _facilitators[msg.sender];
        if (f.bucketCapacity == 0) revert NotFacilitator(msg.sender);
        uint256 newLevel = f.bucketLevel + amount;
        if (newLevel > f.bucketCapacity) revert FacilitatorBucketCapacityExceeded();
        f.bucketLevel = uint128(newLevel);
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        Facilitator storage f = _facilitators[msg.sender];
        // underflows (reverts) if burning more than the facilitator has outstanding
        f.bucketLevel -= uint128(amount);
        _burn(msg.sender, amount);
    }

    function getFacilitatorBucket(address facilitator) external view returns (uint256 capacity, uint256 level) {
        Facilitator storage f = _facilitators[facilitator];
        return (f.bucketCapacity, f.bucketLevel);
    }
}
