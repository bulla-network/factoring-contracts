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
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./DeployConfig.sol";

contract DeployBullaFactoring is DeployConfig {
    // SafeCast reverts on a value that doesn't fit, where uint16(x) would silently truncate it past the constructor's range checks
    using SafeCast for uint256;

    function run() external {
        // Read configuration from environment or use defaults
        _loadConfig();
        
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Default insurer to pool owner (deployer) if not specified
        if (config.insurer == address(0)) {
            config.insurer = deployer;
        }

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
            console.log("Deploying BullaFactoringV2_2...");
            BullaFactoringV2_2 bullaFactoring = new BullaFactoringV2_2(
                IERC20(config.underlyingAsset),
                IInvoiceProviderAdapterV2(config.bullaClaimInvoiceProviderAdapterAddress),
                config.underwriter,
                Permissions(config.depositPermissionsAddress),
                Permissions(config.redeemPermissionsAddress),
                Permissions(config.factoringPermissionsAddress),
                config.bullaDao,
                config.protocolFeeBps.toUint16(),
                config.adminFeeBps.toUint16(),
                config.poolName,
                config.targetYieldBps.toUint16(),
                config.poolTokenName,
                config.poolTokenSymbol,
                config.insurer,
                config.insuranceFeeBps.toUint16(),
                config.impairmentGrossGainBps.toUint16(),
                config.recoveryProfitRatioBps.toUint16()
            );
            config.bullaFactoringAddress = address(bullaFactoring);
            console.log("BullaFactoringV2_2 deployed at:", address(bullaFactoring));
        } else {
            console.log("Using existing BullaFactoringV2_2:", config.bullaFactoringAddress);
        }

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("BullaClaimV2InvoiceProviderAdapterV2:", config.bullaClaimInvoiceProviderAdapterAddress);
        console.log("FactoringPermissions:", config.factoringPermissionsAddress);
        console.log("DepositPermissions:", config.depositPermissionsAddress);
        console.log("BullaFactoringV2_2:", config.bullaFactoringAddress);
    }
}
