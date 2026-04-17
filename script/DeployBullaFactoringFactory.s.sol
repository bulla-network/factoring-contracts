// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/BullaFactoringFactoryV2_1.sol";
import "../contracts/BullaFactoring.sol";
import "../contracts/BullaClaimV2InvoiceProviderAdapterV2.sol";
import "../contracts/interfaces/IInvoiceProviderAdapter.sol";

contract DeployBullaFactoringFactory is Script {
    // Configuration struct to match TypeScript network config
    struct FactoryConfig {
        address bullaClaim;
        address bullaDao;
        address bullaInvoiceAddress;
        address bullaClaimInvoiceProviderAdapterAddress;
        uint16 protocolFeeBps;
    }

    FactoryConfig public config;

    function run() external {
        // Read configuration from environment
        _loadConfig();
        
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying BullaFactoringFactoryV2_1 with account:", deployer);
        console.log("Factory Config:");
        console.log("- BullaClaim:", config.bullaClaim);
        console.log("- BullaDao:", config.bullaDao);
        console.log("- ProtocolFeeBps:", config.protocolFeeBps);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy BullaClaimV2InvoiceProviderAdapterV2 if not provided
        if (config.bullaClaimInvoiceProviderAdapterAddress == address(0)) {
            console.log("Deploying BullaClaimV2InvoiceProviderAdapterV2...");
            BullaClaimV2InvoiceProviderAdapterV2 adapter = new BullaClaimV2InvoiceProviderAdapterV2(
                config.bullaClaim,
                config.bullaInvoiceAddress
            );
            config.bullaClaimInvoiceProviderAdapterAddress = address(adapter);
            console.log("BullaClaimV2InvoiceProviderAdapterV2 deployed at:", address(adapter));
        } else {
            console.log("Using existing BullaClaimInvoiceProviderAdapter:", config.bullaClaimInvoiceProviderAdapterAddress);
        }

        // Compute init bytecode config for BullaFactoringV2_2
        bytes memory initBytecode = type(BullaFactoringV2_2).creationCode;
        uint256 initBytecodeLength = initBytecode.length;
        bytes32 expectedInitBytecodeHash = keccak256(initBytecode);
        console.log("- InitBytecodeLength:", initBytecodeLength);
        console.log("- ExpectedInitBytecodeHash:");
        console.logBytes32(expectedInitBytecodeHash);

        // Deploy BullaFactoringFactoryV2_1
        console.log("Deploying BullaFactoringFactoryV2_1...");
        BullaFactoringFactoryV2_1 factory = new BullaFactoringFactoryV2_1(
            config.bullaClaimInvoiceProviderAdapterAddress,
            config.bullaClaim,
            config.bullaDao,
            config.protocolFeeBps,
            initBytecodeLength,
            expectedInitBytecodeHash
        );
        console.log("BullaFactoringFactoryV2_1 deployed at:", address(factory));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("BullaClaimV2InvoiceProviderAdapterV2:", config.bullaClaimInvoiceProviderAdapterAddress);
        console.log("BullaFactoringFactoryV2_1:", address(factory));
        console.log("Factory Owner (BullaDao):", config.bullaDao);
        console.log("Protocol Fee:", config.protocolFeeBps, "bps");
    }

    function _loadConfig() internal {
        // Load from environment variables (set by the TypeScript wrapper)
        config.bullaClaim = vm.envAddress("BULLA_CLAIM");
        config.bullaDao = vm.envAddress("BULLA_DAO");
        config.bullaInvoiceAddress = vm.envOr("BULLA_INVOICE_ADDRESS", address(0));
        config.bullaClaimInvoiceProviderAdapterAddress = vm.envOr("BULLA_CLAIM_INVOICE_PROVIDER_ADAPTER_ADDRESS", address(0));
        config.protocolFeeBps = uint16(vm.envUint("PROTOCOL_FEE_BPS"));
    }
}
