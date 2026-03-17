// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum EntityType {
    None,
    Individual,
    Business
}

struct KYCRecord {
    bool isKyced;
    EntityType entityType;
    uint64 expiry;
    uint64 approvedAt;
    bytes32 inquiryId;
    bytes32 identityHash; // keccak256(abi.encodePacked(salt, firstName, middleName, lastName)) — salt is stored on the backend
}

interface IBullaKycIssuer {
    function getKycRecord(address _address) external view returns (KYCRecord memory);
}
