// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract GetCodehash is Script {
    function run() external view {
        address pool = vm.envAddress("POOL_ADDRESS");
        bytes32 hash = pool.codehash;
        
        console.log("Pool address:", pool);
        console.log("Codehash:");
        console.logBytes32(hash);
    }
}
