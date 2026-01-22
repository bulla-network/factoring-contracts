// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../interfaces/IZodiacRoles.sol";

/// @title Mock Zodiac Roles Modifier for testing
/// @dev Always returns success for execTransactionWithRole calls
contract MockZodiacRoles is IZodiacRoles {
    /// @notice Tracks calls for test assertions
    struct CallRecord {
        address to;
        uint256 value;
        bytes data;
        Operation operation;
        bytes32 roleKey;
    }
    
    CallRecord[] public calls;
    bool public shouldSucceed = true;

    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool /* shouldRevert */
    ) external override returns (bool success) {
        calls.push(CallRecord({
            to: to,
            value: value,
            data: data,
            operation: operation,
            roleKey: roleKey
        }));
        return shouldSucceed;
    }

    /// @notice Set whether calls should succeed or fail
    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }

    /// @notice Get the number of calls recorded
    function getCallCount() external view returns (uint256) {
        return calls.length;
    }

    /// @notice Clear recorded calls
    function clearCalls() external {
        delete calls;
    }
}
