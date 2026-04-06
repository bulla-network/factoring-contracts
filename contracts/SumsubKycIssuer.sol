// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "./interfaces/IBullaKycIssuer.sol";

contract SumsubKycIssuer is IBullaKycIssuer, Ownable {
    mapping(address => bool) public kycedAddresses;
    address public kycApprover;

    event KycApproved(address indexed _address);
    event KycRevoked(address indexed _address);
    event KycApproverChanged(address indexed oldApprover, address indexed newApprover);

    error UnauthorizedKycApprover(address caller);

    modifier onlyKycApprover() {
        if (msg.sender != kycApprover) revert UnauthorizedKycApprover(msg.sender);
        _;
    }

    constructor(address initialKycApprover) Ownable(_msgSender()) {
        kycApprover = initialKycApprover;
        emit KycApproverChanged(address(0), initialKycApprover);
    }

    function setKycApprover(address _newApprover) external onlyOwner {
        address oldApprover = kycApprover;
        kycApprover = _newApprover;
        emit KycApproverChanged(oldApprover, _newApprover);
    }

    function approve(address _address) external onlyKycApprover {
        kycedAddresses[_address] = true;
        emit KycApproved(_address);
    }

    function revoke(address _address) external onlyKycApprover {
        kycedAddresses[_address] = false;
        emit KycRevoked(_address);
    }

    function isKyced(address _address) external view override returns (bool) {
        return kycedAddresses[_address];
    }
}
