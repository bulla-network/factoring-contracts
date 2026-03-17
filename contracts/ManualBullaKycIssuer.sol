// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import {IBullaKycIssuer, KYCRecord, EntityType} from "./interfaces/IBullaKycIssuer.sol";

contract ManualBullaKycIssuer is IBullaKycIssuer, Ownable {
    mapping(address => KYCRecord) public kycRecords;

    event KycApproved(address indexed _address, EntityType entityType, bytes32 inquiryId, bytes32 identityHash);
    event KycRevoked(address indexed _address);

    constructor() Ownable(_msgSender()) {}

    function approve(
        address _address,
        EntityType _entityType,
        uint64 _expiry,
        bytes32 _inquiryId,
        bytes32 _identityHash
    ) public onlyOwner {
        kycRecords[_address] = KYCRecord({
            isKyced: true,
            entityType: _entityType,
            expiry: _expiry,
            approvedAt: uint64(block.timestamp),
            inquiryId: _inquiryId,
            identityHash: _identityHash
        });
        emit KycApproved(_address, _entityType, _inquiryId, _identityHash);
    }

    function revoke(address _address) public onlyOwner {
        delete kycRecords[_address];
        emit KycRevoked(_address);
    }

    function getKycRecord(address _address) external view override returns (KYCRecord memory) {
        return kycRecords[_address];
    }
}
