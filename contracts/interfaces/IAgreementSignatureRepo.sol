// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAgreementSignatureRepo {
    function hasSigned(address pool, uint256 documentVersion, address participant) external view returns (bool);
}
