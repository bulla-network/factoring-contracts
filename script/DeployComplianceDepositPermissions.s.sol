// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/ComplianceDepositPermissions.sol";
import "../contracts/BullaKycGate.sol";
import "../contracts/interfaces/ISanctionsList.sol";
import "../contracts/interfaces/IBullaKycGate.sol";
import "../contracts/interfaces/IBullaKycIssuer.sol";
import "../contracts/interfaces/IAgreementSignatureRepo.sol";

contract DeployComplianceDepositPermissions is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOY_PK");
        address deployer = vm.addr(deployerPrivateKey);

        // Required addresses — all must be non-zero
        address sanctionsListAddress = vm.envAddress("SANCTIONS_LIST_ADDRESS");
        address agreementSignatureRepoAddress = vm.envAddress("AGREEMENT_SIGNATURE_REPO_ADDRESS");
        address sumsubKycIssuerAddress = vm.envAddress("SUMSUB_KYC_ISSUER_ADDRESS");
        address bullaDao = vm.envAddress("BULLA_DAO");

        // Optional: use existing BullaKycGate or deploy new one
        address bullaKycGateAddress = vm.envOr("BULLA_KYC_GATE_ADDRESS", address(0));

        console.log("Deploying ComplianceDepositPermissions with:");
        console.log("- Deployer:", deployer);
        console.log("- SanctionsList:", sanctionsListAddress);
        console.log("- SumsubKycIssuer:", sumsubKycIssuerAddress);
        console.log("- AgreementSignatureRepo:", agreementSignatureRepoAddress);
        console.log("- BullaDao:", bullaDao);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy BullaKycGate if not provided
        BullaKycGate kycGate;
        if (bullaKycGateAddress == address(0)) {
            console.log("Deploying new BullaKycGate...");
            kycGate = new BullaKycGate();
            bullaKycGateAddress = address(kycGate);
            console.log("BullaKycGate deployed at:", bullaKycGateAddress);

            // Register SumsubKycIssuer with the gate
            kycGate.addIssuer(IBullaKycIssuer(sumsubKycIssuerAddress));
            console.log("Registered SumsubKycIssuer with BullaKycGate");

            // Transfer ownership to Bulla protocol
            kycGate.transferOwnership(bullaDao);
            console.log("Transferred BullaKycGate ownership to BullaDao:", bullaDao);
        } else {
            console.log("Using existing BullaKycGate:", bullaKycGateAddress);
        }

        // Deploy ComplianceDepositPermissions
        ComplianceDepositPermissions permissions = new ComplianceDepositPermissions(
            ISanctionsList(sanctionsListAddress),
            IBullaKycGate(bullaKycGateAddress),
            IAgreementSignatureRepo(agreementSignatureRepoAddress)
        );
        console.log("ComplianceDepositPermissions deployed at:", address(permissions));

        // Transfer ownership to Bulla protocol
        permissions.transferOwnership(bullaDao);
        console.log("Transferred ComplianceDepositPermissions ownership to BullaDao:", bullaDao);

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("BullaKycGate:", bullaKycGateAddress);
        console.log("ComplianceDepositPermissions:", address(permissions));
    }
}
