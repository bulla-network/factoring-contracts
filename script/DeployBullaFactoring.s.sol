// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/BullaClaimV2InvoiceProviderAdapterV2.sol";
import "../contracts/BullaFactoring.sol";
import "../contracts/FactoringPermissions.sol";
import "../contracts/DepositPermissions.sol";
import "../contracts/interfaces/IInvoiceProviderAdapter.sol";
import "../contracts/Permissions.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";

contract DeployBullaFactoring is Script {
    // Configuration struct to match TypeScript network config
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
    }

    NetworkConfig public config;

    function run() external {
        // Read configuration from environment or use defaults
        _loadConfig();
        
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying with account:", deployer);
        console.log("Network Config:");
        console.log("- BullaClaim:", config.bullaClaim);
        console.log("- UnderlyingAsset:", config.underlyingAsset);
        console.log("- Underwriter:", config.underwriter);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy BullaClaimV2InvoiceProviderAdapterV2 if not provided
        if (config.bullaClaimInvoiceProviderAdapterAddress == address(0)) {
            console.log("Deploying BullaClaimV2InvoiceProviderAdapterV2...");
            BullaClaimV2InvoiceProviderAdapterV2 adapter = new BullaClaimV2InvoiceProviderAdapterV2(
                config.bullaClaim,
                config.bullaFrendLendAddress,
                config.bullaInvoiceAddress
            );
            config.bullaClaimInvoiceProviderAdapterAddress = address(adapter);
            console.log("BullaClaimV2InvoiceProviderAdapterV2 deployed at:", address(adapter));
        } else {
            console.log("Using existing BullaClaimInvoiceProviderAdapter:", config.bullaClaimInvoiceProviderAdapterAddress);
        }

        // Deploy FactoringPermissions if not provided
        if (config.factoringPermissionsAddress == address(0)) {
            console.log("Deploying FactoringPermissions...");
            FactoringPermissions factoringPermissions = new FactoringPermissions();
            config.factoringPermissionsAddress = address(factoringPermissions);
            console.log("FactoringPermissions deployed at:", address(factoringPermissions));
        } else {
            console.log("Using existing FactoringPermissions:", config.factoringPermissionsAddress);
        }

        // Deploy DepositPermissions if not provided
        if (config.depositPermissionsAddress == address(0)) {
            console.log("Deploying DepositPermissions...");
            DepositPermissions depositPermissions = new DepositPermissions();
            config.depositPermissionsAddress = address(depositPermissions);
            console.log("DepositPermissions deployed at:", address(depositPermissions));
        } else {
            console.log("Using existing DepositPermissions:", config.depositPermissionsAddress);
        }

        // Reuse DepositPermissions for RedeemPermissions if not provided
        if (config.redeemPermissionsAddress == address(0)) {
            console.log("Reusing DepositPermissions for RedeemPermissions...");
            config.redeemPermissionsAddress = config.depositPermissionsAddress;
            console.log("RedeemPermissions set to DepositPermissions address:", config.redeemPermissionsAddress);
        } else {
            console.log("Using existing RedeemPermissions:", config.redeemPermissionsAddress);
        }

        // Deploy BullaFactoring if not provided
        if (config.bullaFactoringAddress == address(0)) {
            console.log("Deploying BullaFactoringV2...");
            BullaFactoringV2 bullaFactoring = new BullaFactoringV2(
                IERC20(config.underlyingAsset),
                IInvoiceProviderAdapterV2(config.bullaClaimInvoiceProviderAdapterAddress),
                IBullaFrendLendV2(config.bullaFrendLendAddress),
                config.underwriter,
                Permissions(config.depositPermissionsAddress),
                Permissions(config.redeemPermissionsAddress),
                Permissions(config.factoringPermissionsAddress),
                config.bullaDao,
                uint16(config.protocolFeeBps),
                uint16(config.adminFeeBps),
                0, // processingFeeBps
                config.poolName,
                uint16(config.targetYieldBps),
                config.poolTokenName,
                config.poolTokenSymbol
            );
            config.bullaFactoringAddress = address(bullaFactoring);
            console.log("BullaFactoringV2 deployed at:", address(bullaFactoring));
        } else {
            console.log("Using existing BullaFactoringV2:", config.bullaFactoringAddress);
        }

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("BullaClaimV2InvoiceProviderAdapterV2:", config.bullaClaimInvoiceProviderAdapterAddress);
        console.log("FactoringPermissions:", config.factoringPermissionsAddress);
        console.log("DepositPermissions:", config.depositPermissionsAddress);
        console.log("BullaFactoringV2:", config.bullaFactoringAddress);
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
    }
}
