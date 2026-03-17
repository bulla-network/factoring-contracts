// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "./Permissions.sol";
import "./interfaces/IBullaKycIssuer.sol";

contract BullaKycGate is Permissions, Ownable {
    IBullaKycIssuer[] public issuers;

    event IssuerAdded(address indexed issuer);
    event IssuerRemoved(address indexed issuer);

    error MaxIssuersReached();
    error InvalidIssuer();
    error InvalidIssuerIndex();

    constructor() Ownable(_msgSender()) {}

    function isAllowed(address _address) external view override returns (bool) {
        for (uint256 i = 0; i < issuers.length; i++) {
            if (issuers[i].isKyced(_address)) {
                return true;
            }
        }
        return false;
    }

    function addIssuer(IBullaKycIssuer _issuer) public onlyOwner {
        if (address(_issuer) == address(0)) revert InvalidIssuer();
        if (issuers.length >= 256) revert MaxIssuersReached();
        issuers.push(_issuer);
        emit IssuerAdded(address(_issuer));
    }

    function removeIssuer(uint256 index) public onlyOwner {
        if (index >= issuers.length) revert InvalidIssuerIndex();
        address removed = address(issuers[index]);
        issuers[index] = issuers[issuers.length - 1];
        issuers.pop();
        emit IssuerRemoved(removed);
    }

    function getIssuers() external view returns (IBullaKycIssuer[] memory) {
        return issuers;
    }
}
