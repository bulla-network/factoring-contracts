// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import "../interfaces/ISanctionsList.sol";

/// @notice Owner-controlled mock of the Chainalysis sanctions oracle for testnets where Chainalysis is not deployed.
contract MockSanctionsList is ISanctionsList, Ownable {
    mapping(address => bool) public sanctioned;

    event AddedToSanctionsList(address indexed addr);
    event RemovedFromSanctionsList(address indexed addr);

    constructor() Ownable(_msgSender()) {}

    function addToSanctionsList(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            sanctioned[addrs[i]] = true;
            emit AddedToSanctionsList(addrs[i]);
        }
    }

    function removeFromSanctionsList(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            sanctioned[addrs[i]] = false;
            emit RemovedFromSanctionsList(addrs[i]);
        }
    }

    function isSanctioned(address addr) external view override returns (bool) {
        return sanctioned[addr];
    }
}
