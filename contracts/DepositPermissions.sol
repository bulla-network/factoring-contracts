// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/access/Ownable.sol';
import "./Permissions.sol";

contract DepositPermissions is Permissions, Ownable {
    mapping(address => bool) public allowedAddresses;

    constructor() Ownable(_msgSender()) {}

    function isAllowed(address _address) external view override returns (bool) {
        return allowedAddresses[_address];
    }

    function allow(address _address) public onlyOwner {
        allowedAddresses[_address] = true;
    }

    function disallow(address _address) public onlyOwner {
        allowedAddresses[_address] = false;
    }
}