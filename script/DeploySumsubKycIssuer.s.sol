// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/SumsubKycIssuer.sol";

contract DeploySumsubKycIssuer is Script {
    function run() external {
        // Load configuration from environment
        address initialKycApprover = vm.envAddress("INITIAL_KYC_APPROVER");

        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying SumsubKycIssuer with:");
        console.log("- Deployer:", deployer);
        console.log("- Initial KYC Approver:", initialKycApprover);

        vm.startBroadcast(deployerPrivateKey);

        SumsubKycIssuer issuer = new SumsubKycIssuer(initialKycApprover);

        vm.stopBroadcast();

        console.log("SumsubKycIssuer deployed at:", address(issuer));
    }
}
