// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBullaFactoring {
    function setImpairReserve(uint256 _impairReserve) external;
    function assetAddress() external view returns (IERC20);
    function impairReserve() external view returns (uint256);
}

contract SetImpairReserve is Script {
    function run() external {
        // Load configuration from environment
        address bullaFactoringAddress = vm.envAddress("BULLA_FACTORING_ADDRESS");
        uint256 impairReserveAmount = vm.envUint("IMPAIR_RESERVE_AMOUNT");
        
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Setting impair reserve with:");
        console.log("- Deployer:", deployer);
        console.log("- BullaFactoring:", bullaFactoringAddress);
        console.log("- Impair Reserve Amount:", impairReserveAmount);
        
        vm.startBroadcast(deployerPrivateKey);
        
        IBullaFactoring bullaFactoring = IBullaFactoring(bullaFactoringAddress);
        IERC20 assetToken = bullaFactoring.assetAddress();
        uint256 currentImpairReserve = bullaFactoring.impairReserve();
        
        console.log("- Asset Token:", address(assetToken));
        console.log("- Current Impair Reserve:", currentImpairReserve);
        
        // Calculate the amount to add
        uint256 amountToAdd = impairReserveAmount - currentImpairReserve;
        console.log("- Amount to Add:", amountToAdd);
        
        // Check deployer's balance
        uint256 deployerBalance = assetToken.balanceOf(deployer);
        console.log("- Deployer Balance:", deployerBalance);
        
        if (deployerBalance < amountToAdd) {
            revert("Insufficient balance to add to impair reserve");
        }
        
        // Approve the BullaFactoring contract to spend the required amount
        console.log("Approving asset token...");
        bool approvalSuccess = assetToken.approve(bullaFactoringAddress, amountToAdd);
        require(approvalSuccess, "Token approval failed");
        console.log("Token approval successful");
        
        // Set the impair reserve
        console.log("Setting impair reserve...");
        bullaFactoring.setImpairReserve(impairReserveAmount);
        
        vm.stopBroadcast();
        
        console.log("Impair reserve set successfully to:", impairReserveAmount);
    }
}
