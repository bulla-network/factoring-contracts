// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IBullaClaimCore} from "@bulla/contracts-v2/src/interfaces/IBullaClaimCore.sol";
import "../contracts/BullaFactoring.sol";

contract WhitelistCallback is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address bullaFactoringAddress = vm.envAddress("BULLA_FACTORING_ADDRESS");
        address bullaClaimV2Address = vm.envAddress("BULLA_CLAIM_V2_ADDRESS");

        console.log("=== Whitelist Callback Configuration ===");
        console.log("BullaFactoring Address:", bullaFactoringAddress);
        console.log("BullaClaimV2 Address:", bullaClaimV2Address);

        // Get the callback selector
        BullaFactoringV2_2 factoring = BullaFactoringV2_2(bullaFactoringAddress);
        bytes4 reconcileSingleInvoiceSelector = factoring.reconcileSingleInvoice.selector;

        console.log("reconcileSingleInvoice Selector:", vm.toString(reconcileSingleInvoiceSelector));

        vm.startBroadcast(deployerPrivateKey);

        IBullaClaimCore bullaClaimV2 = IBullaClaimCore(bullaClaimV2Address);

        // Add the reconcileSingleInvoice callback to BullaClaimV2 paid callback whitelist
        bullaClaimV2.addToPaidCallbackWhitelist(bullaFactoringAddress, reconcileSingleInvoiceSelector);

        console.log("Successfully whitelisted reconcileSingleInvoice callback on BullaClaimV2");
        console.log("Contract:", bullaFactoringAddress);
        console.log("Selector:", vm.toString(reconcileSingleInvoiceSelector));

        vm.stopBroadcast();

        // Note: BullaClaimV2 doesn't have a public function to check whitelist status, so we can't verify it here
        console.log("Note: BullaClaimV2 whitelist verification not available via public interface");
    }
}
