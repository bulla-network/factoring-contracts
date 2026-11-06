// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../CommonSetup.t.sol";
import {PreDeployChecks} from "../../../script/PreDeployChecks.s.sol";
import {DeployConfig} from "../../../script/DeployConfig.sol";

/// @dev Shaped like the V2.1 adapter: every IInvoiceProviderAdapterV2 function except getImpairTarget.
contract AdapterWithoutImpairTarget {
    function initializeInvoice(uint256) external {}

    function getInvoiceDetails(uint256) external pure returns (IInvoiceProviderAdapterV2.Invoice memory invoice) {
        return invoice;
    }

    function getInvoiceContractAddress(uint256) external pure returns (address) {
        return address(0);
    }

    function getSetPaidInvoiceTarget(uint256) external pure returns (address, bytes4) {
        return (address(0), bytes4(0));
    }
}

/// @dev Has code but none of the functions the checks call.
contract NoInterface {}

/// @title Pre-deployment checks (POOLDEPLOY-01..POOLDEPLOY-10)
/// @notice Spec: bulla-specs deploy-pool.md. Runs script/PreDeployChecks.s.sol against locally deployed
///         Bulla contracts (CommonSetup), injecting the config directly so tests don't share env vars.
contract TestPreDeployChecks is CommonSetup {
    PreDeployChecks internal checks;
    address internal eoa = address(0xE0A);

    function setUp() public override {
        super.setUp();
        checks = new PreDeployChecks();
    }

    // ------------------------------------------------------------------
    // R1: a failed check stops the deploy
    // ------------------------------------------------------------------

    function test_R1_reportRevertsOnAnyFailure() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaFactoringAddress = address(bullaFactoring); // POOLDEPLOY-10 fails
        PreDeployChecks.Result[] memory r = checks.runChecksWith(c, _extras());

        vm.expectRevert(bytes("Pre-deployment checks failed"));
        checks.report(r);
    }

    function test_R1_reportPassesWithOnlyPassSkipAndWarn() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.insurer = address(0); // POOLDEPLOY-09 warns
        c.bullaClaimInvoiceProviderAdapterAddress = address(0); // POOLDEPLOY-01/02 skip
        PreDeployChecks.Result[] memory r = checks.runChecksWith(c, _extras());

        assertEq(_failures(r), 0, "R1: valid config should have no failures");
        checks.report(r); // does not revert
    }

    function test_R1_validConfigPassesEveryCheck() public {
        PreDeployChecks.Result[] memory r = checks.runChecksWith(_validConfig(), _extras());
        for (uint256 i = 0; i < r.length; i++) {
            assertTrue(r[i].status == PreDeployChecks.Status.PASS, string.concat(r[i].id, " should pass: ", r[i].detail));
        }
        assertEq(r.length, 8, "every check scenario reports once");
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-01 Adapter has no code
    // ------------------------------------------------------------------

    function test_POOLDEPLOY01_adapterWithoutCodeFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaClaimInvoiceProviderAdapterAddress = eoa;
        PreDeployChecks.Result[] memory r = checks.runChecksWith(c, _extras());

        _assertStatus(r, "POOLDEPLOY-01", PreDeployChecks.Status.FAIL);
        _assertStatus(r, "POOLDEPLOY-02", PreDeployChecks.Status.SKIP);
        assertTrue(_contains(_detail(r, "POOLDEPLOY-01"), vm.toString(eoa)), "POOLDEPLOY-01: names the adapter");
    }

    function test_POOLDEPLOY01_noAdapterConfiguredSkips() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaClaimInvoiceProviderAdapterAddress = address(0);
        PreDeployChecks.Result[] memory r = checks.runChecksWith(c, _extras());

        _assertStatus(r, "POOLDEPLOY-01", PreDeployChecks.Status.SKIP);
        _assertStatus(r, "POOLDEPLOY-02", PreDeployChecks.Status.SKIP);
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-02 Adapter is missing a function the pool calls
    // ------------------------------------------------------------------

    function test_POOLDEPLOY02_interfaceComesFromCompiledAbi() public view {
        string[] memory sigs = checks.adapterInterfaceSignatures();
        assertEq(sigs.length, 5, "POOLDEPLOY-02: IInvoiceProviderAdapterV2 has 5 functions");
        bool found;
        for (uint256 i = 0; i < sigs.length; i++) {
            if (keccak256(bytes(sigs[i])) == keccak256("getImpairTarget(uint256)")) found = true;
        }
        assertTrue(found, "POOLDEPLOY-02: getImpairTarget read from the compiled ABI");
    }

    function test_POOLDEPLOY02_v21AdapterFailsNamingGetImpairTarget() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaClaimInvoiceProviderAdapterAddress = address(new AdapterWithoutImpairTarget());
        PreDeployChecks.Result[] memory r = checks.runChecksWith(c, _extras());

        _assertStatus(r, "POOLDEPLOY-01", PreDeployChecks.Status.PASS);
        _assertStatus(r, "POOLDEPLOY-02", PreDeployChecks.Status.FAIL);
        string memory detail = _detail(r, "POOLDEPLOY-02");
        assertTrue(_contains(detail, "getImpairTarget(uint256)"), "POOLDEPLOY-02: names the function");
        assertTrue(_contains(detail, "0x0d219c0f"), "POOLDEPLOY-02: names the selector");
        assertFalse(_contains(detail, "getSetPaidInvoiceTarget"), "POOLDEPLOY-02: only missing functions listed");
    }

    function test_POOLDEPLOY02_currentAdapterPasses() public {
        string[] memory missing = checks.adapterMissingSignatures(address(invoiceAdapterBulla));
        assertEq(missing.length, 0, "POOLDEPLOY-02: current adapter implements the interface");
    }

    function test_POOLDEPLOY02_contractWithNoFunctionsMissesAll() public {
        string[] memory missing = checks.adapterMissingSignatures(address(new NoInterface()));
        assertEq(missing.length, 5, "POOLDEPLOY-02: every function missing");
    }

    /// @dev Selectors with leading zero bytes are pushed with a shorter PUSHn.
    function test_POOLDEPLOY02_bytecodeSelectorMatchHandlesLeadingZeros() public view {
        assertTrue(checks.bytecodeHasSelector(hex"00630d219c0f00", bytes4(0x0d219c0f)), "PUSH4");
        assertTrue(checks.bytecodeHasSelector(hex"0061abcd00", bytes4(0x0000abcd)), "PUSH2 for 0x0000abcd");
        assertFalse(checks.bytecodeHasSelector(hex"00620d219c0f", bytes4(0x0d219c0f)), "wrong PUSH width");
        assertFalse(checks.bytecodeHasSelector(hex"630d219c", bytes4(0x0d219c0f)), "truncated");
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-03 Core Bulla contracts exist
    // ------------------------------------------------------------------

    function test_POOLDEPLOY03_bullaClaimZeroFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaClaim = address(0);
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-03", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY03_optionalControllerWithoutCodeFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaFrendLendAddress = eoa;
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-03", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY03_unsetOptionalControllersPass() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaFrendLendAddress = address(0);
        c.bullaInvoiceAddress = address(0);
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-03", PreDeployChecks.Status.PASS);
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-04 Underlying asset is an ERC-20
    // ------------------------------------------------------------------

    function test_POOLDEPLOY04_assetWithoutCodeFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.underlyingAsset = eoa;
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-04", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY04_nonErc20Fails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.underlyingAsset = address(new NoInterface());
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-04", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY04_erc20PassesAndPrintsSymbol() public {
        PreDeployChecks.Result[] memory r = checks.runChecksWith(_validConfig(), _extras());
        _assertStatus(r, "POOLDEPLOY-04", PreDeployChecks.Status.PASS);
        assertTrue(_contains(_detail(r, "POOLDEPLOY-04"), "USDC (6 decimals)"), "POOLDEPLOY-04: prints symbol and decimals");
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-05 Permissions contracts exist
    // ------------------------------------------------------------------

    function test_POOLDEPLOY05_noneConfiguredSkips() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.factoringPermissionsAddress = address(0);
        c.depositPermissionsAddress = address(0);
        c.redeemPermissionsAddress = address(0);
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-05", PreDeployChecks.Status.SKIP);
    }

    function test_POOLDEPLOY05_permissionsWithoutCodeFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.depositPermissionsAddress = eoa;
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-05", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY05_contractWithoutIsAllowedFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.redeemPermissionsAddress = address(new NoInterface());
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-05", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY05_permissionsContractsPass() public {
        _assertStatus(checks.runChecksWith(_validConfig(), _extras()), "POOLDEPLOY-05", PreDeployChecks.Status.PASS);
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-06 Sanctions and KYC contracts exist
    // ------------------------------------------------------------------

    function test_POOLDEPLOY06_noneConfiguredSkips() public {
        PreDeployChecks.Extras memory e = _extras();
        e.sanctionsList = address(0);
        e.kycGate = address(0);
        e.complianceDepositPermissions = address(0);
        _assertStatus(checks.runChecksWith(_validConfig(), e), "POOLDEPLOY-06", PreDeployChecks.Status.SKIP);
    }

    function test_POOLDEPLOY06_configuredWithoutCodeFails() public {
        PreDeployChecks.Extras memory e = _extras();
        e.kycGate = eoa;
        _assertStatus(checks.runChecksWith(_validConfig(), e), "POOLDEPLOY-06", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY06_configuredWithCodePasses() public {
        _assertStatus(checks.runChecksWith(_validConfig(), _extras()), "POOLDEPLOY-06", PreDeployChecks.Status.PASS);
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-09 Pool roles are set
    // ------------------------------------------------------------------

    function test_POOLDEPLOY09_zeroUnderwriterFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.underwriter = address(0);
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-09", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY09_zeroBullaDaoFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaDao = address(0);
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-09", PreDeployChecks.Status.FAIL);
    }

    function test_POOLDEPLOY09_unsetInsurerWarns() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.insurer = address(0);
        _assertStatus(checks.runChecksWith(c, _extras()), "POOLDEPLOY-09", PreDeployChecks.Status.WARN);
    }

    // ------------------------------------------------------------------
    // POOLDEPLOY-10 A pool is already configured
    // ------------------------------------------------------------------

    function test_POOLDEPLOY10_existingPoolFails() public {
        DeployConfig.NetworkConfig memory c = _validConfig();
        c.bullaFactoringAddress = address(bullaFactoring);
        PreDeployChecks.Result[] memory r = checks.runChecksWith(c, _extras());

        _assertStatus(r, "POOLDEPLOY-10", PreDeployChecks.Status.FAIL);
        string memory detail = _detail(r, "POOLDEPLOY-10");
        assertTrue(_contains(detail, vm.toString(address(bullaFactoring))), "POOLDEPLOY-10: prints the pool address");
        assertTrue(_contains(detail, "bullaFactoringAddress"), "POOLDEPLOY-10: says what to clear");
    }

    function test_POOLDEPLOY10_noPoolPasses() public {
        _assertStatus(checks.runChecksWith(_validConfig(), _extras()), "POOLDEPLOY-10", PreDeployChecks.Status.PASS);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _validConfig() internal view returns (DeployConfig.NetworkConfig memory c) {
        c.bullaClaim = address(bullaClaim);
        c.underlyingAsset = address(asset);
        c.underwriter = underwriter;
        c.bullaDao = bullaDao;
        c.protocolFeeBps = protocolFeeBps;
        c.adminFeeBps = adminFeeBps;
        c.poolName = poolName;
        c.targetYieldBps = targetYield;
        c.poolTokenName = poolTokenName;
        c.poolTokenSymbol = poolTokenSymbol;
        c.bullaClaimInvoiceProviderAdapterAddress = address(invoiceAdapterBulla);
        c.factoringPermissionsAddress = address(factoringPermissions);
        c.depositPermissionsAddress = address(depositPermissions);
        c.redeemPermissionsAddress = address(redeemPermissions);
        c.bullaFrendLendAddress = address(bullaFrendLend);
        c.bullaInvoiceAddress = address(bullaInvoice);
        c.bullaFactoringAddress = address(0);
        c.insurer = address(0x1999);
        c.insuranceFeeBps = 100;
        c.impairmentGrossGainBps = 500;
        c.recoveryProfitRatioBps = 5000;
    }

    /// @dev Sanctions/KYC/compliance point at contracts with code.
    function _extras() internal view returns (PreDeployChecks.Extras memory e) {
        e.sanctionsList = address(feeExemptionWhitelist);
        e.kycGate = address(daoMock);
        e.complianceDepositPermissions = address(permissionsWithSafe);
    }

    function _find(PreDeployChecks.Result[] memory r, string memory id) internal pure returns (uint256) {
        for (uint256 i = 0; i < r.length; i++) {
            if (keccak256(bytes(r[i].id)) == keccak256(bytes(id))) return i;
        }
        revert(string.concat("no result for ", id));
    }

    function _assertStatus(PreDeployChecks.Result[] memory r, string memory id, PreDeployChecks.Status expected)
        internal
        pure
    {
        PreDeployChecks.Result memory res = r[_find(r, id)];
        assertEq(uint256(res.status), uint256(expected), string.concat(id, ": ", res.detail));
    }

    function _detail(PreDeployChecks.Result[] memory r, string memory id) internal pure returns (string memory) {
        return r[_find(r, id)].detail;
    }

    function _failures(PreDeployChecks.Result[] memory r) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < r.length; i++) {
            if (r[i].status == PreDeployChecks.Status.FAIL) n++;
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
