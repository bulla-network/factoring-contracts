// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./FactoringPermissions.sol";

/// @title Permissions Factory
/// @author Bulla Network
/// @notice Factory contract for deploying FactoringPermissions contracts
/// @dev Deploys a permissions contract and transfers ownership to the caller
contract PermissionsFactory {
    /// @notice Emitted when a new permissions contract is created
    /// @param permissions Address of the permissions contract
    /// @param owner Address of the permissions owner
    event PermissionsCreated(
        address indexed permissions,
        address indexed owner
    );

    /// @notice Creates a new FactoringPermissions contract
    /// @dev Deploys the contract, whitelists initial addresses, and transfers ownership to caller
    /// @param initialAllowedAddresses Array of addresses to whitelist
    /// @return permissions Address of the new permissions contract
    function createPermissions(
        address[] calldata initialAllowedAddresses
    ) external returns (address permissions) {
        // Deploy permissions contract (factory is initial owner)
        FactoringPermissions _permissions = new FactoringPermissions();

        // Whitelist initial addresses before transferring ownership
        for (uint256 i = 0; i < initialAllowedAddresses.length; i++) {
            _permissions.allow(initialAllowedAddresses[i]);
        }

        // Transfer ownership to caller
        _permissions.transferOwnership(msg.sender);

        permissions = address(_permissions);

        emit PermissionsCreated(permissions, msg.sender);

        return permissions;
    }
}
