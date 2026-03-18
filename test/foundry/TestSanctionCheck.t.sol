// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import 'forge-std/Test.sol';
import { ISanctionsList } from 'contracts/interfaces/ISanctionsList.sol';

// ============ Mock: SanctionsList Oracle ============

contract MockSanctionsList is ISanctionsList {
    mapping(address => bool) public sanctioned;

    function addToSanctionsList(address[] calldata addrs) external {
        for (uint256 i = 0; i < addrs.length; i++) {
            sanctioned[addrs[i]] = true;
        }
    }

    function removeFromSanctionsList(address[] calldata addrs) external {
        for (uint256 i = 0; i < addrs.length; i++) {
            sanctioned[addrs[i]] = false;
        }
    }

    function isSanctioned(address addr) external view override returns (bool) {
        return sanctioned[addr];
    }
}

// ============ Unit Tests: ISanctionsList Interface ============

contract TestSanctionsList is Test {
    MockSanctionsList public oracle;
    address user1 = address(0xCAFE);
    address user2 = address(0xBEEF);
    address user3 = address(0xDEAD);

    function setUp() public {
        oracle = new MockSanctionsList();
    }

    function testCleanAddressIsNotSanctioned() public view {
        assertFalse(oracle.isSanctioned(user1));
    }

    function testSanctionedAddressReturnsTrue() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user1;
        oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(user1));
    }

    function testRemoveFromSanctionsList() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user1;
        oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(user1));

        oracle.removeFromSanctionsList(addrs);
        assertFalse(oracle.isSanctioned(user1));
    }

    function testBatchSanctioning() public {
        address[] memory addrs = new address[](3);
        addrs[0] = user1;
        addrs[1] = user2;
        addrs[2] = user3;
        oracle.addToSanctionsList(addrs);

        assertTrue(oracle.isSanctioned(user1));
        assertTrue(oracle.isSanctioned(user2));
        assertTrue(oracle.isSanctioned(user3));
    }

    function testBatchRemoval() public {
        address[] memory addrs = new address[](2);
        addrs[0] = user1;
        addrs[1] = user2;
        oracle.addToSanctionsList(addrs);

        address[] memory toRemove = new address[](1);
        toRemove[0] = user1;
        oracle.removeFromSanctionsList(toRemove);

        assertFalse(oracle.isSanctioned(user1));
        assertTrue(oracle.isSanctioned(user2));
    }

    function testZeroAddressNotSanctioned() public view {
        assertFalse(oracle.isSanctioned(address(0)));
    }

    function testInterfaceCanBeCalledViaISanctionsList() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user1;
        oracle.addToSanctionsList(addrs);

        ISanctionsList sanctionsList = ISanctionsList(address(oracle));
        assertTrue(sanctionsList.isSanctioned(user1));
        assertFalse(sanctionsList.isSanctioned(user2));
    }
}
