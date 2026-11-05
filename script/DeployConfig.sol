// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/// @notice Shared env-driven config for DeployBullaFactoring and PreDeployChecks, so both read
///         exactly the same inputs (set by scripts/deploy-bullaFactoring.ts).
abstract contract DeployConfig is Script {
    struct NetworkConfig {
        address bullaClaim;
        address underlyingAsset;
        address underwriter;
        address bullaDao;
        uint256 protocolFeeBps;
        uint256 adminFeeBps;
        string poolName;
        uint256 targetYieldBps;
        string poolTokenName;
        string poolTokenSymbol;
        address bullaClaimInvoiceProviderAdapterAddress;
        address factoringPermissionsAddress;
        address depositPermissionsAddress;
        address redeemPermissionsAddress;
        address bullaFrendLendAddress;
        address bullaInvoiceAddress;
        address bullaFactoringAddress;
        address insurer;
        uint256 insuranceFeeBps;
        uint256 impairmentGrossGainBps;
        uint256 recoveryProfitRatioBps;
    }

    NetworkConfig public config;

    function getConfig() external view returns (NetworkConfig memory) {
        return config;
    }

    function _loadConfig() internal {
        // Load from environment variables (set by the TypeScript wrapper)
        config.bullaClaim = vm.envAddress("BULLA_CLAIM");
        config.underlyingAsset = vm.envAddress("UNDERLYING_ASSET");
        config.underwriter = vm.envAddress("UNDERWRITER");
        config.bullaDao = vm.envAddress("BULLA_DAO");
        config.protocolFeeBps = vm.envUint("PROTOCOL_FEE_BPS");
        config.adminFeeBps = vm.envUint("ADMIN_FEE_BPS");
        config.poolName = vm.envString("POOL_NAME");
        config.targetYieldBps = vm.envUint("TARGET_YIELD_BPS");
        config.poolTokenName = vm.envString("POOL_TOKEN_NAME");
        config.poolTokenSymbol = vm.envString("POOL_TOKEN_SYMBOL");

        // Optional addresses (may be zero)
        config.bullaClaimInvoiceProviderAdapterAddress = vm.envOr("BULLA_CLAIM_INVOICE_PROVIDER_ADAPTER_ADDRESS", address(0));
        config.factoringPermissionsAddress = vm.envOr("FACTORING_PERMISSIONS_ADDRESS", address(0));
        config.depositPermissionsAddress = vm.envOr("DEPOSIT_PERMISSIONS_ADDRESS", address(0));
        config.redeemPermissionsAddress = vm.envOr("REDEEM_PERMISSIONS_ADDRESS", address(0));
        config.bullaFrendLendAddress = vm.envOr("BULLA_FREND_LEND_ADDRESS", address(0));
        config.bullaInvoiceAddress = vm.envOr("BULLA_INVOICE_ADDRESS", address(0));
        config.bullaFactoringAddress = vm.envOr("BULLA_FACTORING_ADDRESS", address(0));
        config.insurer = vm.envOr("INSURER_ADDRESS", address(0));
        config.insuranceFeeBps = vm.envOr("INSURANCE_FEE_BPS", uint256(100));
        config.impairmentGrossGainBps = vm.envOr("IMPAIRMENT_GROSS_GAIN_BPS", uint256(500));
        config.recoveryProfitRatioBps = vm.envOr("RECOVERY_PROFIT_RATIO_BPS", uint256(5000));
    }
}
