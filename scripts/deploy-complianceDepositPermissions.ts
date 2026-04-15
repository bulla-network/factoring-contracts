import { getNetworkOnlyConfig, getRpcUrl } from './network-config';
import { getUnderwriterAddress } from './deploy-sumsubKycIssuer';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkInteractive } from './utils/interactive-prompt';
import {
    updateBullaKycGateFromBroadcast,
    updateComplianceDepositPermissionsFromBroadcast,
} from './utils/update-config';
import { verifyBroadcastContracts } from './utils/verify-forge';

/**
 * Chainalysis OFAC sanctions oracle addresses per network.
 * See: https://go.chainalysis.com/chainalysis-oracle-docs.html
 */
const CHAINALYSIS_SANCTIONS_LIST: Record<string, string> = {
    mainnet: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb',
    polygon: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb',
    base: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb',
    arbitrum: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb',
    sepolia: '0x0000000000000000000000000000000000000000', // No Chainalysis on testnet — will need a mock
};

function getSanctionsListAddress(network: string): string {
    const address = CHAINALYSIS_SANCTIONS_LIST[network];
    if (!address) {
        throw new Error(`No sanctions list address configured for network '${network}'`);
    }
    if (address === '0x0000000000000000000000000000000000000000') {
        throw new Error(
            `Sanctions list address is zero for network '${network}'. Deploy a mock SanctionsList first, then pass its address via SANCTIONS_LIST_ADDRESS env var.`,
        );
    }
    return address;
}

/**
 * Deploy ComplianceDepositPermissions workflow
 *
 * Deploys BullaKycGate (if not already deployed), registers SumsubKycIssuer,
 * and deploys ComplianceDepositPermissions with all required dependencies.
 */
export async function deployComplianceDepositPermissionsWorkflow(
    network: string,
    privateKey: string,
    overrides?: {
        sanctionsListAddress?: string;
        bullaKycGateAddress?: string;
    },
): Promise<void> {
    console.log(`🚀 Deploying ComplianceDepositPermissions to ${network} network...\n`);

    // Get network configuration
    const config = getNetworkOnlyConfig(network);

    // Check if already deployed
    if (
        config.complianceDepositPermissionsAddress &&
        config.complianceDepositPermissionsAddress !== '0x0000000000000000000000000000000000000000'
    ) {
        console.log('⚠️  ComplianceDepositPermissions already deployed on this network:');
        console.log(`   Address: ${config.complianceDepositPermissionsAddress}`);
        console.log('   Skipping deployment.\n');
        return;
    }

    // Resolve sanctions list address
    const sanctionsListAddress = overrides?.sanctionsListAddress || getSanctionsListAddress(network);

    // SumsubKycIssuer must already be deployed
    if (!config.sumsubKycIssuerAddress || config.sumsubKycIssuerAddress === '0x0000000000000000000000000000000000000000') {
        throw new Error(
            `SumsubKycIssuer not deployed on '${network}'. Run deploy-sumsubKycIssuer first.`,
        );
    }

    // AgreementSignatureRepo must already be deployed
    if (
        !config.agreementSignatureRepoAddress ||
        config.agreementSignatureRepoAddress === '0x0000000000000000000000000000000000000000'
    ) {
        throw new Error(
            `AgreementSignatureRepo not deployed on '${network}'. Run deploy-agreementSignatureRepo first.`,
        );
    }

    // BullaKycGate — use existing or deploy new
    const bullaKycGateAddress =
        overrides?.bullaKycGateAddress || config.bullaKycGateAddress || '0x0000000000000000000000000000000000000000';

    // Display deployment info
    console.log('📋 Deployment Configuration:');
    console.log(`   Sanctions List: ${sanctionsListAddress}`);
    console.log(`   SumsubKycIssuer: ${config.sumsubKycIssuerAddress}`);
    console.log(`   AgreementSignatureRepo: ${config.agreementSignatureRepoAddress}`);
    console.log(`   BullaDao: ${config.bullaDao}`);
    if (bullaKycGateAddress === '0x0000000000000000000000000000000000000000') {
        console.log('   BullaKycGate: Will deploy new');
    } else {
        console.log(`   BullaKycGate: ${bullaKycGateAddress} (existing)`);
    }
    console.log('');

    console.log(`📡 Starting ComplianceDepositPermissions deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
        SANCTIONS_LIST_ADDRESS: sanctionsListAddress,
        SUMSUB_KYC_ISSUER_ADDRESS: config.sumsubKycIssuerAddress,
        AGREEMENT_SIGNATURE_REPO_ADDRESS: config.agreementSignatureRepoAddress,
        BULLA_DAO: config.bullaDao,
        BULLA_KYC_GATE_ADDRESS: bullaKycGateAddress,
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript(
            'script/DeployComplianceDepositPermissions.s.sol:DeployComplianceDepositPermissions',
            rpcUrl,
            privateKey,
            env,
            network,
        );

        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ ComplianceDepositPermissions deployment completed successfully!');
                console.log(`🎉 Your ComplianceDepositPermissions is now live on ${network}!`);

                // Update network config with new addresses
                console.log('\n📝 Updating network-config.ts...');
                updateBullaKycGateFromBroadcast('DeployComplianceDepositPermissions.s.sol', network);
                updateComplianceDepositPermissionsFromBroadcast(
                    'DeployComplianceDepositPermissions.s.sol',
                    network,
                );

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployComplianceDepositPermissions.s.sol', network, false);

                console.log('\n📝 Next steps:');
                console.log('   1. Check network-config.ts for the updated addresses');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Set this as the depositPermissions on the factoring pool');

                resolve();
            } else {
                reject(new Error(`ComplianceDepositPermissions deployment failed with exit code ${code}`));
            }
        });

        forgeProcess.on('error', error => {
            if ((error as any).code === 'ENOENT') {
                reject(new Error('Forge not found. Make sure Foundry is installed and in your PATH.'));
            } else {
                reject(error);
            }
        });
    });
}

/**
 * Launcher: Get network and private key interactively, then run workflow
 */
async function deployComplianceDepositPermissionsLauncher(): Promise<void> {
    try {
        const network = await getNetworkInteractive();
        const privateKey = await getPrivateKeyInteractively();

        // Allow overriding sanctions list address via env var (useful for testnets with mocks)
        const sanctionsListOverride = process.env.SANCTIONS_LIST_ADDRESS;

        await deployComplianceDepositPermissionsWorkflow(network, privateKey, {
            sanctionsListAddress: sanctionsListOverride,
        });
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deployComplianceDepositPermissionsLauncher();
}
