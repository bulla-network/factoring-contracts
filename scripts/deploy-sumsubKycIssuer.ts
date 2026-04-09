import { getAvailablePools, getDeployedPoolConfig, getNetworkOnlyConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkInteractive } from './utils/interactive-prompt';
import { updateSumsubKycIssuerFromBroadcast } from './utils/update-config';
import { verifyBroadcastContracts } from './utils/verify-forge';

function getUnderwriterAddress(network: string): string {
    const pools = getAvailablePools(network);
    for (const pool of pools) {
        const poolConfig = getDeployedPoolConfig(network, pool);
        if (poolConfig?.underwriter) {
            return poolConfig.underwriter;
        }
    }
    throw new Error(`No deployed pool with an underwriter found on network '${network}'`);
}

/**
 * Deploy SumsubKycIssuer workflow (can be called with parameters or standalone)
 */
export async function deploySumsubKycIssuerWorkflow(network: string, privateKey: string): Promise<void> {
    console.log(`🚀 Deploying SumsubKycIssuer to ${network} network...\n`);

    // Get network configuration
    const config = getNetworkOnlyConfig(network);

    // Check if already deployed
    if (
        config.sumsubKycIssuerAddress &&
        config.sumsubKycIssuerAddress !== '0x0000000000000000000000000000000000000000'
    ) {
        console.log('⚠️  SumsubKycIssuer already deployed on this network:');
        console.log(`   Address: ${config.sumsubKycIssuerAddress}`);
        console.log('   Skipping deployment.\n');
        return;
    }

    // Use the underwriter address as the initial KYC approver
    const initialKycApprover = getUnderwriterAddress(network);

    // Display deployment info
    console.log('📋 Deployment Configuration:');
    console.log(`   Initial KYC Approver (underwriter): ${initialKycApprover}\n`);

    console.log(`📡 Starting SumsubKycIssuer deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
        INITIAL_KYC_APPROVER: initialKycApprover,
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript(
            'script/DeploySumsubKycIssuer.s.sol:DeploySumsubKycIssuer',
            rpcUrl,
            privateKey,
            env,
            network,
        );

        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ SumsubKycIssuer deployment completed successfully!');
                console.log(`🎉 Your SumsubKycIssuer is now live on ${network}!`);

                // Update network config with new address
                console.log('\n📝 Updating network-config.ts...');
                updateSumsubKycIssuerFromBroadcast('DeploySumsubKycIssuer.s.sol', network);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeploySumsubKycIssuer.s.sol', network, false);

                console.log('\n📝 Next steps:');
                console.log('   1. Check network-config.ts for the updated SumsubKycIssuer address');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Register this issuer with BullaKycGate if needed');

                resolve();
            } else {
                reject(new Error(`SumsubKycIssuer deployment failed with exit code ${code}`));
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
async function deploySumsubKycIssuerLauncher(): Promise<void> {
    try {
        const network = await getNetworkInteractive();
        const privateKey = await getPrivateKeyInteractively();

        await deploySumsubKycIssuerWorkflow(network, privateKey);
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deploySumsubKycIssuerLauncher();
}
