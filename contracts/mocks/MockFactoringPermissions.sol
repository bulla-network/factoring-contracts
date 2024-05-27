// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Permissions.sol";

contract MockFactoringPermissions is Permissions {
    mapping(address => bool) public allowedAddresses;

    function isAllowed(address _address) external view override returns (bool) {
        return allowedAddresses[_address];
    }

    function allow(address _address) public {
        allowedAddresses[_address] = true;
    }

    function disallow(address _address) public {
        allowedAddresses[_address] = false;
    }
}