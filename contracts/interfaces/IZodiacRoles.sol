// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

/// @title Zodiac Roles Modifier Interface
/// @notice Minimal interface for executing transactions through Zodiac Roles Modifier
/// @dev See https://github.com/gnosisguild/zodiac-modifier-roles
interface IZodiacRoles {
    /// @notice Operation types for transaction execution
    enum Operation {
        Call,
        DelegateCall
    }

    /// @notice Executes a transaction with role-based permission checking
    /// @param to Target address for the transaction
    /// @param value ETH value to send
    /// @param data Calldata for the transaction
    /// @param operation Operation type (Call or DelegateCall)
    /// @param roleKey The role identifier that grants permission
    /// @param shouldRevert If true, reverts on failure; if false, returns success status
    /// @return success Whether the execution succeeded (only meaningful if shouldRevert is false)
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    ) external returns (bool success);
}
