// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { ISanctionsList } from 'contracts/interfaces/ISanctionsList.sol';

// ============ Fork Tests: Chainalysis Sanctions Oracle (Mainnet) ============
// Run with: forge test --match-contract TestSanctionCheckFork --fork-url $ETH_RPC_URL

contract TestSanctionCheckFork is Test {
    ISanctionsList public oracle;

    // Chainalysis sanctions oracle — same address on all EVM chains
    address constant SANCTIONS_ORACLE = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;

    // Known sanctioned address (added to Chainalysis oracle in block 19562392)
    address constant SANCTIONED_ADDRESS = 0x38735f03b30FbC022DdD06ABED01F0Ca823C6a94;

    // A regular EOA that should not be sanctioned
    address constant CLEAN_ADDRESS = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // vitalik.eth

    function setUp() public {
        oracle = ISanctionsList(SANCTIONS_ORACLE);
    }

    function testOracleIsDeployed() public view {
        uint256 codeSize;
        address oracleAddr = SANCTIONS_ORACLE;
        assembly {
            codeSize := extcodesize(oracleAddr)
        }
        assertGt(codeSize, 0, "Sanctions oracle should have code deployed");
    }

    function testCleanAddressIsNotSanctioned() public view {
        assertFalse(oracle.isSanctioned(CLEAN_ADDRESS), "vitalik.eth should not be sanctioned");
    }

    function testSanctionedAddressIsSanctioned() public view {
        assertTrue(oracle.isSanctioned(SANCTIONED_ADDRESS), "Known sanctioned address should be sanctioned");
    }

    function testZeroAddressIsNotSanctioned() public view {
        assertFalse(oracle.isSanctioned(address(0)), "Zero address should not be sanctioned");
    }

    function testRandomAddressIsNotSanctioned() public view {
        assertFalse(oracle.isSanctioned(address(0x1234567890)), "Random address should not be sanctioned");
    }
}
