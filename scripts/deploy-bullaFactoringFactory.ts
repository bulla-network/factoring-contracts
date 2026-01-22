import { getNetworkOnlyConfig, getRpcUrl, DEFAULT_PROTOCOL_FEE_BPS } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkInteractive } from './utils/interactive-prompt';
import { verifyBroadcastContracts } from './utils/verify-forge';

/**
 * Deploy BullaFactoringFactoryV2_1 workflow
 */
export async function deployFactoryWorkflow(network: string, privateKey: string): Promise<void> {
    console.log(`🏭 Deploying BullaFactoringFactoryV2_1 to ${network}...\n`);

    // Get network-specific configuration
    const config = getNetworkOnlyConfig(network);

    // Display deployment info
    console.log('📋 Factory Configuration:');
    console.log(`   Network: ${network}`);
    console.log(`   BullaDao (Owner): ${config.bullaDao}`);
    console.log(`   BullaFrendLend: ${config.bullaFrendLendAddress || '(none)'}`);
    console.log(`   Invoice Provider Adapter: ${config.BullaClaimInvoiceProviderAdapterAddress || '(will deploy new)'}`);
    console.log(`   Protocol Fee: ${DEFAULT_PROTOCOL_FEE_BPS} bps (${DEFAULT_PROTOCOL_FEE_BPS / 100}%)\n`);

    console.log(`📡 Starting deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
        // Network-specific config
        BULLA_CLAIM: config.bullaClaim,
        BULLA_DAO: config.bullaDao,
        BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress || '',
        BULLA_INVOICE_ADDRESS: config.bullaInvoiceAddress || '',
        BULLA_CLAIM_INVOICE_PROVIDER_ADAPTER_ADDRESS: config.BullaClaimInvoiceProviderAdapterAddress || '',
        PROTOCOL_FEE_BPS: DEFAULT_PROTOCOL_FEE_BPS.toString(),
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript(
            'script/DeployBullaFactoringFactory.s.sol:DeployBullaFactoringFactory',
            rpcUrl,
            privateKey,
            env,
            network,
        );

        // Handle forge process events with verification
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Factory deployment completed successfully!');
                console.log(`🏭 BullaFactoringFactoryV2_1 is now live on ${network}!`);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployBullaFactoringFactory.s.sol', network, false);

                console.log('\n📝 Next steps:');
                console.log('   1. Update network-config.ts with the factory address');
                console.log('   2. Add the factory to your subgraph data sources');
                console.log('   3. Factory owner (BullaDao) can now configure factory settings');
                console.log('   4. Users can create new pools via createPool()');

                resolve();
            } else {
                reject(new Error(`Deployment failed with exit code ${code}`));
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
async function deployFactoryLauncher(): Promise<void> {
    try {
        // Get network interactively
        const network = await getNetworkInteractive();

        // Get private key interactively
        const privateKey = await getPrivateKeyInteractively();

        await deployFactoryWorkflow(network, privateKey);
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deployFactoryLauncher();
}
