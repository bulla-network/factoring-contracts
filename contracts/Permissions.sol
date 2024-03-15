// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract Permissions {
    event AccessGranted(address indexed _account);
    event AccessRevoked(address indexed _account);

    function isAllowed(address _address) virtual external view returns (bool);
}