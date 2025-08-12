// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/BullaClaimV2InvoiceProviderAdapterV2.sol";

contract DeployAdapter is Script {
    function run() external {
        // Load configuration from environment
        address bullaClaim = vm.envAddress("BULLA_CLAIM");
        address bullaFrendLend = vm.envOr("BULLA_FREND_LEND_ADDRESS", address(0));
        address bullaInvoice = vm.envOr("BULLA_INVOICE_ADDRESS", address(0));
        
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying BullaClaimV2InvoiceProviderAdapterV2 with:");
        console.log("- Deployer:", deployer);
        console.log("- BullaClaim:", bullaClaim);
        console.log("- BullaFrendLend:", bullaFrendLend);
        console.log("- BullaInvoice:", bullaInvoice);
        
        vm.startBroadcast(deployerPrivateKey);
        
        BullaClaimV2InvoiceProviderAdapterV2 adapter = new BullaClaimV2InvoiceProviderAdapterV2(
            bullaClaim,
            bullaFrendLend,
            bullaInvoice
        );
        
        vm.stopBroadcast();
        
        console.log("BullaClaimV2InvoiceProviderAdapterV2 deployed at:", address(adapter));
    }
}
