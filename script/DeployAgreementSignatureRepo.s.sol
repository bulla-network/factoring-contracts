// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/AgreementSignatureRepo.sol";

contract DeployAgreementSignatureRepo is Script {
    function run() external {
        // Load configuration from environment
        address initialSignatureApprover = vm.envAddress("INITIAL_SIGNATURE_APPROVER");

        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying AgreementSignatureRepo with:");
        console.log("- Deployer:", deployer);
        console.log("- Initial Signature Approver:", initialSignatureApprover);

        vm.startBroadcast(deployerPrivateKey);

        AgreementSignatureRepo repo = new AgreementSignatureRepo(initialSignatureApprover);

        vm.stopBroadcast();

        console.log("AgreementSignatureRepo deployed at:", address(repo));
    }
}
