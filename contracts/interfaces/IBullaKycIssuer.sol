// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBullaKycIssuer {
    function isKyced(address _address) external view returns (bool);
}
