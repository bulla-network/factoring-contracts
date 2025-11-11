// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IBullaFrendLendV2} from "@bulla/contracts-v2/src/interfaces/IBullaFrendLendV2.sol";
import {IBullaClaimCore} from "@bulla/contracts-v2/src/interfaces/IBullaClaimCore.sol";
import "../contracts/BullaFactoring.sol";

contract WhitelistCallback is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address bullaFrendLendAddress = vm.envAddress("BULLA_FREND_LEND_ADDRESS");
        address bullaFactoringAddress = vm.envAddress("BULLA_FACTORING_ADDRESS");
        address bullaClaimV2Address = vm.envAddress("BULLA_CLAIM_V2_ADDRESS");

        console.log("=== Whitelist Callback Configuration ===");
        console.log("BullaFrendLend Address:", bullaFrendLendAddress);
        console.log("BullaFactoring Address:", bullaFactoringAddress);
        console.log("BullaClaimV2 Address:", bullaClaimV2Address);

        // Get the callback selectors
        BullaFactoringV2_1 factoring = BullaFactoringV2_1(bullaFactoringAddress);
        bytes4 onLoanOfferAcceptedSelector = factoring.onLoanOfferAccepted.selector;
        bytes4 reconcileSingleInvoiceSelector = factoring.reconcileSingleInvoice.selector;
        
        console.log("onLoanOfferAccepted Selector:", vm.toString(onLoanOfferAcceptedSelector));
        console.log("reconcileSingleInvoice Selector:", vm.toString(reconcileSingleInvoiceSelector));

        vm.startBroadcast(deployerPrivateKey);

        IBullaFrendLendV2 bullaFrendLend = IBullaFrendLendV2(bullaFrendLendAddress);
        IBullaClaimCore bullaClaimV2 = IBullaClaimCore(bullaClaimV2Address);
        
        // Add the onLoanOfferAccepted callback to BullaFrendLend whitelist
        bullaFrendLend.addToCallbackWhitelist(bullaFactoringAddress, onLoanOfferAcceptedSelector);
        
        console.log("Successfully whitelisted onLoanOfferAccepted callback on BullaFrendLend");
        console.log("Contract:", bullaFactoringAddress);
        console.log("Selector:", vm.toString(onLoanOfferAcceptedSelector));

        // Add the reconcileSingleInvoice callback to BullaClaimV2 paid callback whitelist
        bullaClaimV2.addToPaidCallbackWhitelist(bullaFactoringAddress, reconcileSingleInvoiceSelector);
        
        console.log("Successfully whitelisted reconcileSingleInvoice callback on BullaClaimV2");
        console.log("Contract:", bullaFactoringAddress);
        console.log("Selector:", vm.toString(reconcileSingleInvoiceSelector));

        vm.stopBroadcast();

        // Verify the whitelists were successful
        bool isFrendLendWhitelisted = bullaFrendLend.isCallbackWhitelisted(bullaFactoringAddress, onLoanOfferAcceptedSelector);
        console.log("Verification - BullaFrendLend is whitelisted:", isFrendLendWhitelisted);
        
        if (!isFrendLendWhitelisted) {
            console.log("Warning: onLoanOfferAccepted callback was not successfully whitelisted on BullaFrendLend");
        }

        // Note: BullaClaimV2 doesn't have a public function to check whitelist status, so we can't verify it here
        console.log("Note: BullaClaimV2 whitelist verification not available via public interface");
    }
}
