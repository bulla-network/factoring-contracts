// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IBullaFrendLendV2} from "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import "../contracts/BullaFactoring.sol";

contract WhitelistCallback is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address bullaFrendLendAddress = vm.envAddress("BULLA_FREND_LEND_ADDRESS");
        address bullaFactoringAddress = vm.envAddress("BULLA_FACTORING_ADDRESS");

        console.log("=== Whitelist Callback Configuration ===");
        console.log("BullaFrendLend Address:", bullaFrendLendAddress);
        console.log("BullaFactoring Address:", bullaFactoringAddress);

        // Get the callback selector
        BullaFactoringV2_1 factoring = BullaFactoringV2_1(bullaFactoringAddress);
        bytes4 callbackSelector = factoring.onLoanOfferAccepted.selector;
        
        console.log("Callback Selector:", vm.toString(callbackSelector));

        vm.startBroadcast(deployerPrivateKey);

        IBullaFrendLendV2 bullaFrendLend = IBullaFrendLendV2(bullaFrendLendAddress);
        
        // Add the callback to whitelist
        bullaFrendLend.addToCallbackWhitelist(bullaFactoringAddress, callbackSelector);
        
        console.log("Successfully whitelisted callback");
        console.log("Contract:", bullaFactoringAddress);
        console.log("Selector:", vm.toString(callbackSelector));

        vm.stopBroadcast();

        // Verify the whitelist was successful
        bool isWhitelisted = bullaFrendLend.isCallbackWhitelisted(bullaFactoringAddress, callbackSelector);
        console.log("Verification - Is whitelisted:", isWhitelisted);
        
        if (!isWhitelisted) {
            console.log("Warning: Callback was not successfully whitelisted");
        }
    }
}
