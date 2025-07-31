// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import '@openzeppelin/contracts/access/Ownable.sol';
import "./Permissions.sol";
import "./interfaces/IBullaFactoring.sol";

contract PermissionsWithReconcile is Permissions, Ownable {
    mapping(address => bool) public allowedAddresses;
    IBullaFactoring public bullaFactoringPool;

    constructor() Ownable(msg.sender) {}

    function setBullaFactoringPool(address _bullaFactoringPool) public onlyOwner {
        bullaFactoringPool = IBullaFactoring(_bullaFactoringPool);
    }

    function isAllowed(address _address) external view override returns (bool) {
        // First check if address is allowed
        if (!allowedAddresses[_address]) {
            return false;
        }

        // Then check if there are any paid invoices to reconcile
        (uint256[] memory paidInvoices,) = bullaFactoringPool.viewPoolStatus();
        
        // If there are paid invoices, deny access (return false)
        if (paidInvoices.length > 0) {
            return false;
        }

        return true;
    }

    function allow(address _address) public onlyOwner {
        allowedAddresses[_address] = true;
    }

    function disallow(address _address) public onlyOwner {
        allowedAddresses[_address] = false;
    }
} 