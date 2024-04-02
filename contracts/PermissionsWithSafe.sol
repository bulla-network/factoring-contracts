// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import "./Permissions.sol";

contract PermissionsWithSafe is Permissions {
    GnosisSafe public safe;

    constructor(address _safeAddress) {
        require(_safeAddress != address(0), "Invalid Safe address");
        safe = GnosisSafe(payable(_safeAddress));
    }

    function isAllowed(address _address) override external view returns (bool) {
        return safe.isOwner(_address);
    }
}