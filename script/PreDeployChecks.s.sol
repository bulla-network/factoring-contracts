// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "./DeployConfig.sol";

/// @title PreDeployChecks
/// @notice Read-only checks run against the target chain before DeployBullaFactoring broadcasts.
///         Spec: bulla-specs deploy-pool.md, scenarios POOLDEPLOY-01..POOLDEPLOY-10.
/// @dev Reads the same env vars as DeployBullaFactoring (via DeployConfig), plus:
///      - SANCTIONS_LIST_ADDRESS, BULLA_KYC_GATE_ADDRESS, COMPLIANCE_DEPOSIT_PERMISSIONS_ADDRESS (optional, POOLDEPLOY-06)
///      Run without --broadcast. Exits non-zero if any check fails.
contract PreDeployChecks is DeployConfig {
    enum Status {
        PASS,
        FAIL,
        SKIP,
        WARN
    }

    struct Result {
        string id;
        Status status;
        string detail;
    }

    /// @notice Inputs besides the deploy config (POOLDEPLOY-06).
    struct Extras {
        address sanctionsList;
        address kycGate;
        address complianceDepositPermissions;
    }

    string internal constant ADAPTER_INTERFACE_ARTIFACT =
        "/artifacts/foundry/IInvoiceProviderAdapter.sol/IInvoiceProviderAdapterV2.json";

    /// @dev Arbitrary account used to probe isAllowed (scripts may not use address(this))
    address internal constant PROBE_ACCOUNT = address(0xdead);

    address public sanctionsListAddress;
    address public kycGateAddress;
    address public complianceDepositPermissionsAddress;

    Result[] internal results;

    // ------------------------------------------------------------------
    // Entry points
    // ------------------------------------------------------------------

    function run() external {
        report(runChecks());
    }

    /// @notice Prints every result and reverts if any check failed (R1: a failed check stops the deploy).
    function report(Result[] memory r) public pure {
        uint256 passed;
        uint256 failed;
        uint256 skipped;
        uint256 warned;
        for (uint256 i = 0; i < r.length; i++) {
            console.log(string.concat("[", r[i].id, "] ", _statusLabel(r[i].status), " ", r[i].detail));
            if (r[i].status == Status.PASS) passed++;
            else if (r[i].status == Status.FAIL) failed++;
            else if (r[i].status == Status.SKIP) skipped++;
            else warned++;
        }

        string memory summary = string.concat(
            "Pre-deployment checks: ",
            vm.toString(passed),
            " passed, ",
            vm.toString(failed),
            " failed, ",
            vm.toString(skipped),
            " skipped, ",
            vm.toString(warned),
            " warnings"
        );

        if (failed > 0) {
            console.log(string.concat(summary, " - ABORTING"));
            revert("Pre-deployment checks failed");
        }
        console.log(summary);
    }

    /// @notice Loads config from env and runs every check. Never reverts on a failed check.
    function runChecks() public returns (Result[] memory) {
        _loadConfig();
        return runChecksWith(config, _loadExtras());
    }

    /// @notice Runs every check against the given inputs, without reading env. Never reverts on a failed check.
    function runChecksWith(NetworkConfig memory c, Extras memory e) public returns (Result[] memory) {
        delete results;
        config = c;
        sanctionsListAddress = e.sanctionsList;
        kycGateAddress = e.kycGate;
        complianceDepositPermissionsAddress = e.complianceDepositPermissions;

        _checkAdapter(); // POOLDEPLOY-01, POOLDEPLOY-02
        _checkCoreBullaContracts(); // POOLDEPLOY-03
        _checkAsset(); // POOLDEPLOY-04
        _checkPermissions(); // POOLDEPLOY-05
        _checkComplianceDependencies(); // POOLDEPLOY-06
        _checkRoles(); // POOLDEPLOY-09
        _checkNoExistingPool(); // POOLDEPLOY-10

        return results;
    }

    // ------------------------------------------------------------------
    // Reusable check primitives (public so tests can call them directly)
    // ------------------------------------------------------------------

    /// @notice Function signatures of IInvoiceProviderAdapterV2 as compiled in this build.
    function adapterInterfaceSignatures() public view returns (string[] memory) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), ADAPTER_INTERFACE_ARTIFACT));
        return vm.parseJsonKeys(json, ".methodIdentifiers");
    }

    /// @notice Signatures from the compiled interface that `adapter` does not implement.
    function adapterMissingSignatures(address adapter) public returns (string[] memory) {
        string[] memory sigs = adapterInterfaceSignatures();
        string[] memory missing = new string[](sigs.length);
        uint256 count;
        bytes memory code = adapter.code;

        for (uint256 i = 0; i < sigs.length; i++) {
            bytes4 selector = bytes4(keccak256(bytes(sigs[i])));
            if (!bytecodeHasSelector(code, selector) && !_probeDispatches(adapter, selector)) {
                missing[count++] = sigs[i];
            }
        }

        assembly ("memory-safe") {
            mstore(missing, count)
        }
        return missing;
    }

    /// @notice True if `code` pushes `selector` onto the stack (how the Solidity dispatcher matches it).
    /// @dev Selectors with leading zero bytes are pushed with a shorter PUSHn, so strip them first.
    function bytecodeHasSelector(bytes memory code, bytes4 selector) public pure returns (bool) {
        uint32 sel = uint32(selector);
        uint256 width = 4;
        while (width > 1 && (sel >> (8 * (width - 1))) == 0) width--;

        bytes1 pushOp = bytes1(uint8(0x5f + width)); // PUSH1 = 0x60
        if (code.length <= width) return false;

        for (uint256 i = 0; i + width < code.length; i++) {
            if (code[i] != pushOp) continue;
            bool matches = true;
            for (uint256 j = 0; j < width; j++) {
                if (uint8(code[i + 1 + j]) != uint8(sel >> (8 * (width - 1 - j)))) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-01, POOLDEPLOY-02: adapter
    // ------------------------------------------------------------------

    function _checkAdapter() internal {
        address adapter = config.bullaClaimInvoiceProviderAdapterAddress;
        if (adapter == address(0)) {
            _skip("POOLDEPLOY-01", "fresh adapter (none configured; deploy script will deploy one)");
            _skip("POOLDEPLOY-02", "fresh adapter (none configured; deploy script will deploy one)");
            return;
        }

        if (adapter.code.length == 0) {
            _fail("POOLDEPLOY-01", string.concat("adapter ", vm.toString(adapter), " has no code on this chain"));
            _skip("POOLDEPLOY-02", "adapter has no code");
            return;
        }
        _pass(
            "POOLDEPLOY-01",
            string.concat("adapter ", vm.toString(adapter), " has code (", vm.toString(adapter.code.length), " bytes)")
        );

        string[] memory missing = adapterMissingSignatures(adapter);
        if (missing.length == 0) {
            _pass("POOLDEPLOY-02", string.concat("adapter implements all ", vm.toString(adapterInterfaceSignatures().length), " IInvoiceProviderAdapterV2 functions"));
        } else {
            string memory list;
            for (uint256 i = 0; i < missing.length; i++) {
                bytes4 sel = bytes4(keccak256(bytes(missing[i])));
                list = string.concat(list, i == 0 ? "" : ", ", missing[i], " (", vm.toString(abi.encodePacked(sel)), ")");
            }
            _fail("POOLDEPLOY-02", string.concat("adapter missing ", list));
        }
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-03..POOLDEPLOY-06: dependencies
    // ------------------------------------------------------------------

    function _checkCoreBullaContracts() internal {
        string memory problems;
        problems = _requireCode(problems, "bullaClaim", config.bullaClaim, true);
        problems = _requireCode(problems, "bullaFrendLend", config.bullaFrendLendAddress, false);
        problems = _requireCode(problems, "bullaInvoice", config.bullaInvoiceAddress, false);
        _record("POOLDEPLOY-03", problems, "core Bulla contracts have code");
    }

    function _checkAsset() internal {
        address asset = config.underlyingAsset;
        if (asset == address(0) || asset.code.length == 0) {
            _fail("POOLDEPLOY-04", string.concat("underlying asset ", vm.toString(asset), " has no code"));
            return;
        }

        (bool okDecimals, bytes memory dec) = asset.staticcall(abi.encodeWithSignature("decimals()"));
        (bool okSupply, bytes memory sup) = asset.staticcall(abi.encodeWithSignature("totalSupply()"));
        (bool okSymbol, bytes memory sym) = asset.staticcall(abi.encodeWithSignature("symbol()"));

        if (!okDecimals || dec.length < 32 || !okSupply || sup.length < 32 || !okSymbol || sym.length == 0) {
            _fail("POOLDEPLOY-04", string.concat("underlying asset ", vm.toString(asset), " does not answer decimals/totalSupply/symbol"));
            return;
        }

        _pass(
            "POOLDEPLOY-04",
            string.concat(
                "asset ", vm.toString(asset), " is ", _decodeSymbol(sym), " (", vm.toString(abi.decode(dec, (uint256))), " decimals)"
            )
        );
    }

    function _checkPermissions() internal {
        address[3] memory addrs =
            [config.factoringPermissionsAddress, config.depositPermissionsAddress, config.redeemPermissionsAddress];
        string[3] memory labels = ["factoringPermissions", "depositPermissions", "redeemPermissions"];

        string memory problems;
        uint256 configured;
        for (uint256 i = 0; i < 3; i++) {
            if (addrs[i] == address(0)) continue;
            configured++;
            if (addrs[i].code.length == 0) {
                problems = _append(problems, string.concat(labels[i], " ", vm.toString(addrs[i]), " has no code"));
                continue;
            }
            (bool ok, bytes memory ret) =
                addrs[i].staticcall(abi.encodeWithSignature("isAllowed(address)", PROBE_ACCOUNT));
            if (!ok || ret.length != 32) {
                problems = _append(problems, string.concat(labels[i], " ", vm.toString(addrs[i]), " does not answer isAllowed(address)"));
            }
        }

        if (configured == 0) {
            _skip("POOLDEPLOY-05", "no permissions configured (deploy script will deploy new ones)");
            return;
        }
        _record("POOLDEPLOY-05", problems, "permissions contracts have code and answer isAllowed");
    }

    function _checkComplianceDependencies() internal {
        if (sanctionsListAddress == address(0) && kycGateAddress == address(0) && complianceDepositPermissionsAddress == address(0)) {
            _skip("POOLDEPLOY-06", "no sanctions/KYC contracts configured for this network");
            return;
        }
        string memory problems;
        problems = _requireCode(problems, "sanctionsList", sanctionsListAddress, false);
        problems = _requireCode(problems, "bullaKycGate", kycGateAddress, false);
        problems = _requireCode(problems, "complianceDepositPermissions", complianceDepositPermissionsAddress, false);
        _record("POOLDEPLOY-06", problems, "configured sanctions/KYC contracts have code");
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-09, POOLDEPLOY-10: pool parameters
    // ------------------------------------------------------------------

    function _checkRoles() internal {
        string memory problems;
        if (config.underwriter == address(0)) problems = _append(problems, "underwriter is zero");
        if (config.bullaDao == address(0)) problems = _append(problems, "bullaDao is zero");
        if (bytes(problems).length > 0) {
            _fail("POOLDEPLOY-09", problems);
            return;
        }
        if (config.insurer == address(0)) {
            _warn("POOLDEPLOY-09", "INSURER_ADDRESS not set; insurer will default to the deployer");
            return;
        }
        _pass("POOLDEPLOY-09", string.concat("underwriter, bullaDao and insurer ", vm.toString(config.insurer), " set"));
    }

    function _checkNoExistingPool() internal {
        if (config.bullaFactoringAddress != address(0)) {
            _fail(
                "POOLDEPLOY-10",
                string.concat(
                    "pool already configured at ",
                    vm.toString(config.bullaFactoringAddress),
                    "; clear bullaFactoringAddress in scripts/network-config.ts to redeploy"
                )
            );
            return;
        }
        _pass("POOLDEPLOY-10", "no existing pool configured");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _loadExtras() internal view returns (Extras memory e) {
        e.sanctionsList = vm.envOr("SANCTIONS_LIST_ADDRESS", address(0));
        e.kycGate = vm.envOr("BULLA_KYC_GATE_ADDRESS", address(0));
        e.complianceDepositPermissions = vm.envOr("COMPLIANCE_DEPOSIT_PERMISSIONS_ADDRESS", address(0));
    }

    /// @dev A call to a selector the contract doesn't dispatch (and no fallback) reverts with empty data.
    function _probeDispatches(address target, bytes4 selector) internal returns (bool) {
        (bool ok, bytes memory ret) = target.call(abi.encodePacked(selector, uint256(1)));
        return ok || ret.length > 0;
    }

    function _requireCode(string memory problems, string memory label, address addr, bool required)
        internal
        view
        returns (string memory)
    {
        if (addr == address(0)) {
            return required ? _append(problems, string.concat(label, " is zero")) : problems;
        }
        if (addr.code.length == 0) {
            return _append(problems, string.concat(label, " ", vm.toString(addr), " has no code"));
        }
        return problems;
    }

    function _decodeSymbol(bytes memory ret) internal pure returns (string memory) {
        if (ret.length == 32) {
            // bytes32-returning tokens (e.g. MKR)
            bytes32 raw = abi.decode(ret, (bytes32));
            uint256 len;
            while (len < 32 && raw[len] != 0) len++;
            bytes memory out = new bytes(len);
            for (uint256 i = 0; i < len; i++) out[i] = raw[i];
            return string(out);
        }
        return abi.decode(ret, (string));
    }

    function _append(string memory list, string memory item) internal pure returns (string memory) {
        return bytes(list).length == 0 ? item : string.concat(list, "; ", item);
    }

    function _record(string memory id, string memory problems, string memory passDetail) internal {
        if (bytes(problems).length > 0) _fail(id, problems);
        else _pass(id, passDetail);
    }

    function _pass(string memory id, string memory detail) internal {
        results.push(Result(id, Status.PASS, detail));
    }

    function _fail(string memory id, string memory detail) internal {
        results.push(Result(id, Status.FAIL, detail));
    }

    function _skip(string memory id, string memory detail) internal {
        results.push(Result(id, Status.SKIP, detail));
    }

    function _warn(string memory id, string memory detail) internal {
        results.push(Result(id, Status.WARN, detail));
    }

    function _statusLabel(Status s) internal pure returns (string memory) {
        if (s == Status.PASS) return "PASS";
        if (s == Status.FAIL) return "FAIL";
        if (s == Status.SKIP) return "SKIP";
        return "WARN";
    }
}
