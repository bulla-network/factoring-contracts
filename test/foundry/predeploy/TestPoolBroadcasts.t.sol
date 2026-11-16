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
    }

    uint256 internal constant EXCEPTION_COUNT = 8;

    /// The listed exceptions (R6), by chain id and address, each with its reason. Adding one needs review.
    function _exceptions() internal pure returns (uint256[EXCEPTION_COUNT] memory chainIds, address[EXCEPTION_COUNT] memory pools) {
        // Pre-V2.1, deployed before broadcasts were kept:
        //   Sepolia V1 TCS test pool (the subgraph's "Main") and V1 Fundora test pool
        //   Polygon V0 TCS and V1 TCS ("Bulla TCS Factoring Pool - Polygon V2")
        //   Mainnet V1 TCS, Base V1 TCS, Redbelly V1 TARAM
        // Sepolia Fundora V2.2 test pool: its broadcast was never committed, on any branch (config added in 0925d87)
        chainIds = [uint256(11155111), 11155111, 137, 137, 1, 8453, 151, 11155111];
        pools = [
            0xDF0fCe31285dcAB9124bF763AB9E5466723BeF35,
            0x9efBa474E79e7e37C87AB5CAf3D32347Bb9e604F,
            0x573119CF113281270F21cFE6537482E84D0300eF,
            0xA7033191Eb07DC6205015075B204Ba0544bc460d,
            0x0af8C15D19058892cDEA66C8C74B7D7bB696FaD5,
            0x1968f9440724B3148C8152190eeCb18a2F3b2eec,
            0x8f5952d2122A8DF42a3dcB5286D7576ff640cF5D,
            0x8ce8Fe0C4aDf44469f138A8389bDA91cC721A515
        ];
    }

    function _isException(uint256 chainId, address pool) internal pure returns (bool) {
        (uint256[EXCEPTION_COUNT] memory chainIds, address[EXCEPTION_COUNT] memory pools) = _exceptions();
        for (uint256 e; e < EXCEPTION_COUNT; e++) {
            if (chainIds[e] == chainId && pools[e] == pool) return true;
        }
        return false;
    }

    function test_POOLDEPLOY15_everyConfiguredPoolHasItsBroadcast() public view {
        ConfiguredPool[] memory pools = configuredPools(vm.readFile(POOLS));
        assertGt(pools.length, 0, "POOLDEPLOY-15: no pools parsed from pools.json");

        string memory missing;
        for (uint256 i; i < pools.length; i++) {
            if (_isException(pools[i].chainId, pools[i].addr)) continue;
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

    function test_POOLDEPLOY15_everyExceptionIsAConfiguredPool() public view {
        // So the list can't keep an exception for a pool that left the config, or one with a mistyped address
        ConfiguredPool[] memory pools = configuredPools(vm.readFile(POOLS));
        (uint256[EXCEPTION_COUNT] memory chainIds, address[EXCEPTION_COUNT] memory addrs) = _exceptions();
        for (uint256 e; e < EXCEPTION_COUNT; e++) {
            bool found;
            for (uint256 i; i < pools.length; i++) {
                if (pools[i].chainId == chainIds[e] && pools[i].addr == addrs[e]) found = true;
            }
            assertTrue(found, string.concat("POOLDEPLOY-15: exception not in pools.json: ", vm.toString(addrs[e])));
        }
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

    /// Every pool in pools.json, with its chain, network and display name.
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
                vm.parseJsonAddress(json, string.concat(key, ".address"))
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
