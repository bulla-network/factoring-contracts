// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title Every configured pool has its deploy broadcast (POOLDEPLOY-15)
/// @notice Spec: bulla-specs deploy-pool.md, R6 and POOLDEPLOY-15. Reads the pool config, bulla_registry_export/pools.json
///         (DEV-2937), and the committed broadcasts under broadcast/DeployBullaFactoring.s.sol/<chainId>/, so it needs no RPC.
contract TestPoolBroadcasts is Test {
    string internal constant POOLS = "bulla_registry_export/pools.json";
    string internal constant BROADCASTS = "broadcast/DeployBullaFactoring.s.sol/";

    struct ConfiguredPool {
        uint256 chainId;
        string network;
        string displayName;
        address addr;
        string version;
    }

    /// V0 and V1 pools were deployed before broadcasts were kept, so pools.json's `version` exempts them
    function _predatesBroadcasts(ConfiguredPool memory pool) internal pure returns (bool) {
        return _eq(pool.version, "V0") || _eq(pool.version, "V1");
    }

    /// The one pool from V2.1 on with no broadcast: the Sepolia Fundora V2.2 test pool ("Test Pool V2.1" in
    /// pools.json). Its broadcast was never committed, on any branch (config added in 0925d87). Adding another needs review.
    uint256 internal constant LOST_BROADCAST_CHAIN_ID = 11155111;
    address internal constant LOST_BROADCAST_POOL = 0x8ce8Fe0C4aDf44469f138A8389bDA91cC721A515;

    function _isExempt(ConfiguredPool memory pool) internal pure returns (bool) {
        return _predatesBroadcasts(pool) || (pool.chainId == LOST_BROADCAST_CHAIN_ID && pool.addr == LOST_BROADCAST_POOL);
    }

    function test_POOLDEPLOY15_everyConfiguredPoolHasItsBroadcast() public view {
        ConfiguredPool[] memory pools = configuredPools(vm.readFile(POOLS));
        assertGt(pools.length, 0, "POOLDEPLOY-15: no pools parsed from pools.json");

        string memory missing;
        for (uint256 i; i < pools.length; i++) {
            if (_isExempt(pools[i])) continue;
            if (!broadcastCreatesPool(pools[i].chainId, pools[i].addr)) {
                missing = string.concat(
                    missing,
                    "\n  ",
                    pools[i].network,
                    " (",
                    vm.toString(pools[i].chainId),
                    ") ",
                    pools[i].displayName,
                    " ",
                    vm.toString(pools[i].addr)
                );
            }
        }
        assertEq(bytes(missing).length, 0, string.concat("POOLDEPLOY-15: pools with no deploy broadcast:", missing));
    }

    function test_POOLDEPLOY15_parsesEveryPoolInTheConfig() public view {
        string memory src = vm.readFile(POOLS);
        // Every pool has exactly one deployBlock, and nothing else does
        assertEq(
            configuredPools(src).length, _count(bytes(src), bytes('"deployBlock"')), "POOLDEPLOY-15: parser missed a pool"
        );
    }

    function test_POOLDEPLOY15_lostBroadcastPoolIsAConfiguredV2Pool() public view {
        // So the exception can't outlive its pool, carry a mistyped address, or cover a pool the version rule already does
        ConfiguredPool[] memory pools = configuredPools(vm.readFile(POOLS));
        bool found;
        for (uint256 i; i < pools.length; i++) {
            if (pools[i].chainId != LOST_BROADCAST_CHAIN_ID || pools[i].addr != LOST_BROADCAST_POOL) continue;
            found = true;
            assertFalse(_predatesBroadcasts(pools[i]), "POOLDEPLOY-15: the lost-broadcast pool is V0/V1, so it needs no exception");
            assertFalse(broadcastCreatesPool(pools[i].chainId, pools[i].addr), "POOLDEPLOY-15: the lost broadcast is committed now; drop the exception");
        }
        assertTrue(found, "POOLDEPLOY-15: the lost-broadcast pool is not in pools.json");
    }

    function test_POOLDEPLOY15_poolWithoutBroadcastIsCaught() public view {
        // Arbitrum TCS Wyoming's address is only a pool on Arbitrum; no Sepolia broadcast creates it
        assertTrue(broadcastCreatesPool(42161, 0xA7033191Eb07DC6205015075B204Ba0544bc460d), "POOLDEPLOY-15: Arbitrum pool not found");
        assertFalse(broadcastCreatesPool(11155111, 0xA7033191Eb07DC6205015075B204Ba0544bc460d), "POOLDEPLOY-15: matched on the wrong chain");
        assertFalse(broadcastCreatesPool(42161, address(0xdead)), "POOLDEPLOY-15: matched an address nobody deployed");
    }

    function test_POOLDEPLOY15_onlyPoolContractsCount() public view {
        // The Arbitrum v2.2 adapter was created in the same broadcast as the pool, but it isn't a pool
        assertFalse(broadcastCreatesPool(42161, 0x7B3776dcCDb3965Ab9d414F5c9Db5a07177Ea449), "POOLDEPLOY-15: counted an adapter as a pool");
    }

    // ------------------------------------------------------------------
    // Broadcasts
    // ------------------------------------------------------------------

    /// True if a committed DeployBullaFactoring broadcast for `chainId` creates a BullaFactoring contract at `pool`.
    function broadcastCreatesPool(uint256 chainId, address pool) public view returns (bool) {
        string memory dir = string.concat(BROADCASTS, vm.toString(chainId));
        if (!vm.exists(dir)) return false;
        Vm.DirEntry[] memory entries = vm.readDir(dir);
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].isDir || !_endsWith(entries[i].path, ".json")) continue;
            string memory json = vm.readFile(entries[i].path);
            for (uint256 t; ; t++) {
                string memory key = string.concat("$.transactions[", vm.toString(t), "]");
                if (!vm.keyExistsJson(json, key)) break;
                if (!vm.keyExistsJson(json, string.concat(key, ".contractName"))) continue;
                if (!_startsWith(_jsonString(json, string.concat(key, ".contractName")), "BullaFactoring")) continue;
                if (!_eq(_jsonString(json, string.concat(key, ".transactionType")), "CREATE")) continue;
                if (vm.parseJsonAddress(json, string.concat(key, ".contractAddress")) == pool) return true;
            }
        }
        return false;
    }

    function _jsonString(string memory json, string memory key) internal pure returns (string memory) {
        bytes memory raw = vm.parseJson(json, key);
        // null (e.g. a call's contractName) decodes to empty bytes
        if (raw.length == 0) return "";
        return vm.parseJsonString(json, key);
    }

    // ------------------------------------------------------------------
    // pools.json
    // ------------------------------------------------------------------

    /// Every pool in pools.json, with its chain, network, display name and contract version.
    function configuredPools(string memory json) public view returns (ConfiguredPool[] memory out) {
        uint256 n;
        while (vm.keyExistsJson(json, string.concat("$.pools[", vm.toString(n), "]"))) n++;
        out = new ConfiguredPool[](n);
        for (uint256 i; i < n; i++) {
            string memory key = string.concat("$.pools[", vm.toString(i), "]");
            out[i] = ConfiguredPool(
                vm.parseJsonUint(json, string.concat(key, ".chainId")),
                vm.parseJsonString(json, string.concat(key, ".network")),
                vm.parseJsonString(json, string.concat(key, ".displayName")),
                vm.parseJsonAddress(json, string.concat(key, ".address")),
                vm.parseJsonString(json, string.concat(key, ".version"))
            );
        }
    }

    // ------------------------------------------------------------------
    // String helpers
    // ------------------------------------------------------------------

    function _count(bytes memory hay, bytes memory needle) internal pure returns (uint256 c) {
        if (needle.length > hay.length) return 0;
        for (uint256 i; i <= hay.length - needle.length; i++) {
            bool ok = true;
            for (uint256 j; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) c++;
        }
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory p = bytes(prefix);
        if (a.length < p.length) return false;
        for (uint256 i; i < p.length; i++) {
            if (a[i] != p[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory x = bytes(suffix);
        if (a.length < x.length) return false;
        for (uint256 i; i < x.length; i++) {
            if (a[a.length - x.length + i] != x[i]) return false;
        }
        return true;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
