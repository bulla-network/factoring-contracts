// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "./interfaces/IBullaKycIssuer.sol";

contract ManualBullaKycIssuer is IBullaKycIssuer, Ownable {
    mapping(address => bool) public kycedAddresses;

    event KycApproved(address indexed _address);
    event KycRevoked(address indexed _address);

    constructor() Ownable(_msgSender()) {}

    function approve(address _address) public onlyOwner {
        kycedAddresses[_address] = true;
        emit KycApproved(_address);
    }

    function revoke(address _address) public onlyOwner {
        kycedAddresses[_address] = false;
        emit KycRevoked(_address);
    }

    function isKyced(address _address) external view override returns (bool) {
        return kycedAddresses[_address];
    }
}
