import { getNetworkOnlyConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkInteractive } from './utils/interactive-prompt';
import { updateMockSanctionsListFromBroadcast } from './utils/update-config';
import { verifyBroadcastContracts } from './utils/verify-forge';

/**
 * Deploy MockSanctionsList workflow (testnets only — production networks use the real Chainalysis oracle)
 */
export async function deployMockSanctionsListWorkflow(network: string, privateKey: string): Promise<void> {
    if (network !== 'sepolia') {
        throw new Error(
            `MockSanctionsList is only intended for testnets. ` +
                `Network '${network}' should use the real Chainalysis oracle (already configured).`,
        );
    }

    console.log(`🚀 Deploying MockSanctionsList to ${network} network...\n`);

    // Get network configuration
    const config = getNetworkOnlyConfig(network);

    // Check if already deployed
    if (
        config.sanctionsListAddress &&
        config.sanctionsListAddress !== '0x0000000000000000000000000000000000000000'
    ) {
        console.log('⚠️  Sanctions list already configured on this network:');
        console.log(`   Address: ${config.sanctionsListAddress}`);
        console.log('   Skipping deployment.\n');
        return;
    }

    console.log('📋 Deployment Configuration:');
    console.log('   (no constructor args — deployer becomes the owner)\n');

    console.log(`📡 Starting MockSanctionsList deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript(
            'script/DeployMockSanctionsList.s.sol:DeployMockSanctionsList',
            rpcUrl,
            privateKey,
            env,
            network,
        );

        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ MockSanctionsList deployment completed successfully!');
                console.log(`🎉 Your MockSanctionsList is now live on ${network}!`);

                // Update network config with new address
                console.log('\n📝 Updating network-config.ts...');
                updateMockSanctionsListFromBroadcast('DeployMockSanctionsList.s.sol', network);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployMockSanctionsList.s.sol', network, false);

                console.log('\n📝 Next steps:');
                console.log('   1. Check network-config.ts for the updated sanctionsListAddress');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Use addToSanctionsList(addrs) to add test sanctioned addresses');

                resolve();
            } else {
                reject(new Error(`MockSanctionsList deployment failed with exit code ${code}`));
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
async function deployMockSanctionsListLauncher(): Promise<void> {
    try {
        const network = await getNetworkInteractive();
        const privateKey = await getPrivateKeyInteractively();

        await deployMockSanctionsListWorkflow(network, privateKey);
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deployMockSanctionsListLauncher();
}
