// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/mocks/MockSanctionsList.sol";

contract DeployMockSanctionsList is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying MockSanctionsList with:");
        console.log("- Deployer / Owner:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MockSanctionsList sanctionsList = new MockSanctionsList();

        vm.stopBroadcast();

        console.log("MockSanctionsList deployed at:", address(sanctionsList));
    }
}
