// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPermissions {
    function isAllowed(address _address) external view returns (bool);
}