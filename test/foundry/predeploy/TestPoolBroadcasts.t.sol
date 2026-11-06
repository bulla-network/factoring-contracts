// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title Every configured pool has its deploy broadcast (POOLDEPLOY-15)
/// @notice Spec: bulla-specs deploy-pool.md, R6 and POOLDEPLOY-15. Reads scripts/network-config.ts and the committed
///         broadcasts under broadcast/DeployBullaFactoring.s.sol/<chainId>/, so it needs no RPC.
contract TestPoolBroadcasts is Test {
    string internal constant CONFIG = "scripts/network-config.ts";
    string internal constant BROADCASTS = "broadcast/DeployBullaFactoring.s.sol/";

    struct ConfiguredPool {
        string network;
        string pool;
        address addr;
    }

    /// The listed exceptions (R6), keyed by chain id and address, each with its reason. Adding one needs review.
    function _isException(uint256 chainId, address pool) internal pure returns (bool) {
        // Pre-V2.1: Polygon TCS "Bulla TCS Factoring Pool - Polygon V2", deployed before broadcasts were kept
        if (chainId == 137 && pool == 0xA7033191Eb07DC6205015075B204Ba0544bc460d) return true;
        // Sepolia Fundora V2.2 test pool: its broadcast was never committed, on any branch (config added in 0925d87)
        if (chainId == 11155111 && pool == 0x8ce8Fe0C4aDf44469f138A8389bDA91cC721A515) return true;
        return false;
    }

    function test_POOLDEPLOY15_everyConfiguredPoolHasItsBroadcast() public view {
        ConfiguredPool[] memory pools = configuredPools(vm.readFile(CONFIG));
        assertGt(pools.length, 0, "POOLDEPLOY-15: no pools parsed from network-config.ts");

        string memory missing;
        for (uint256 i; i < pools.length; i++) {
            uint256 chainId = _chainId(pools[i].network);
            if (_isException(chainId, pools[i].addr)) continue;
            if (!broadcastCreatesPool(chainId, pools[i].addr)) {
                missing = string.concat(
                    missing, "\n  ", pools[i].network, " (", vm.toString(chainId), ") ", pools[i].pool, " ", vm.toString(pools[i].addr)
                );
            }
        }
        assertEq(bytes(missing).length, 0, string.concat("POOLDEPLOY-15: pools with no deploy broadcast:", missing));
    }

    function test_POOLDEPLOY15_parsesEveryPoolAddressInTheConfig() public view {
        string memory src = vm.readFile(CONFIG);
        assertEq(
            configuredPools(src).length,
            _count(bytes(src), bytes("bullaFactoringAddress: '0x")),
            "POOLDEPLOY-15: parser missed a bullaFactoringAddress"
        );
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
    // network-config.ts
    // ------------------------------------------------------------------

    /// Every bullaFactoringAddress in getDeploymentConfig, with the network and pool `case` it sits under.
    /// Networks are `case '<name>':` at 8 spaces of indentation, pools at 16 (the file's switch layout).
    function configuredPools(string memory src) public pure returns (ConfiguredPool[] memory out) {
        bytes memory b = bytes(src);
        ConfiguredPool[] memory found = new ConfiguredPool[](_count(b, bytes("bullaFactoringAddress: '0x")));
        uint256 n;
        string memory network;
        string memory pool;
        uint256 lineStart;
        for (uint256 i; i <= b.length; i++) {
            if (i < b.length && b[i] != "\n") continue;
            bytes memory line = _slice(b, lineStart, i);
            lineStart = i + 1;

            uint256 indent = _indent(line);
            (bool isCase, string memory name) = _caseName(line, indent);
            if (isCase && indent == 8) network = name;
            else if (isCase && indent == 16) pool = name;

            int256 at = _indexOf(line, bytes("bullaFactoringAddress: '0x"));
            if (at >= 0) {
                uint256 start = uint256(at) + bytes("bullaFactoringAddress: '").length;
                found[n++] = ConfiguredPool(network, pool, vm.parseAddress(string(_slice(line, start, start + 42))));
            }
        }
        out = new ConfiguredPool[](n);
        for (uint256 i; i < n; i++) out[i] = found[i];
    }

    function _caseName(bytes memory line, uint256 indent) internal pure returns (bool, string memory) {
        bytes memory prefix = bytes("case '");
        if (line.length < indent + prefix.length) return (false, "");
        for (uint256 i; i < prefix.length; i++) {
            if (line[indent + i] != prefix[i]) return (false, "");
        }
        uint256 start = indent + prefix.length;
        uint256 end = start;
        while (end < line.length && line[end] != "'") end++;
        return (true, string(_slice(line, start, end)));
    }

    function _chainId(string memory network) internal pure returns (uint256) {
        if (_eq(network, "sepolia")) return 11155111;
        if (_eq(network, "polygon")) return 137;
        if (_eq(network, "mainnet")) return 1;
        if (_eq(network, "base")) return 8453;
        if (_eq(network, "arbitrum")) return 42161;
        revert(string.concat("POOLDEPLOY-15: unknown network ", network));
    }

    // ------------------------------------------------------------------
    // String helpers
    // ------------------------------------------------------------------

    function _indent(bytes memory line) internal pure returns (uint256 i) {
        while (i < line.length && line[i] == " ") i++;
    }

    function _slice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i; i < out.length; i++) out[i] = b[start + i];
    }

    function _indexOf(bytes memory hay, bytes memory needle) internal pure returns (int256) {
        if (needle.length > hay.length) return -1;
        for (uint256 i; i <= hay.length - needle.length; i++) {
            bool ok = true;
            for (uint256 j; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return int256(i);
        }
        return -1;
    }

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
