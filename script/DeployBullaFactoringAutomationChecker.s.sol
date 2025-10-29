// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/BullaFactoringAutomationChecker.sol";

contract DeployBullaFactoringAutomationChecker is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying BullaFactoringAutomationCheckerV2_1");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        BullaFactoringAutomationCheckerV2_1 checker = new BullaFactoringAutomationCheckerV2_1();

        vm.stopBroadcast();

        console.log("BullaFactoringAutomationCheckerV2_1 deployed at:", address(checker));
    }
}

