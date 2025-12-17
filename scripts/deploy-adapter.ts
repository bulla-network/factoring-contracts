import { getNetworkOnlyConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkInteractive } from './utils/interactive-prompt';
import { updateAdapterFromBroadcast } from './utils/update-config';
import { verifyBroadcastContracts } from './utils/verify-forge';

/**
 * Deploy adapter workflow (can be called with parameters or standalone)
 */
export async function deployAdapterWorkflow(network: string, privateKey: string): Promise<void> {
    console.log(`🚀 Deploying BullaClaimV2InvoiceProviderAdapterV2 to ${network} network...\n`);

    // Get network configuration (adapter is network-only, not pool-specific)
    const config = getNetworkOnlyConfig(network);

    // Check if adapter is already deployed
    if (
        config.BullaClaimInvoiceProviderAdapterAddress &&
        config.BullaClaimInvoiceProviderAdapterAddress !== '0x0000000000000000000000000000000000000000'
    ) {
        console.log('⚠️  Adapter already deployed on this network:');
        console.log(`   Address: ${config.BullaClaimInvoiceProviderAdapterAddress}`);
        console.log('   Skipping deployment.\n');
        return;
    }

    // Display deployment info
    console.log('📋 Deployment Configuration:');
    console.log(`   BullaClaim: ${config.bullaClaim}`);
    console.log(`   BullaFrendLend: ${config.bullaFrendLendAddress || 'Not set'}`);
    console.log(`   BullaInvoice: ${config.bullaInvoiceAddress || 'Not set'}\n`);

    console.log(`📡 Starting adapter deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
        // Adapter-specific config
        BULLA_CLAIM: config.bullaClaim,
        BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress || '0x0000000000000000000000000000000000000000',
        BULLA_INVOICE_ADDRESS: config.bullaInvoiceAddress || '0x0000000000000000000000000000000000000000',
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript('script/DeployAdapter.s.sol:DeployAdapter', rpcUrl, privateKey, env, network);

        // Handle forge process events with verification
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Adapter deployment completed successfully!');
                console.log(`🎉 Your BullaClaimV2InvoiceProviderAdapterV2 is now live on ${network}!`);

                // Update network config with new adapter address
                console.log('\n📝 Updating network-config.ts...');
                updateAdapterFromBroadcast('DeployAdapter.s.sol', network);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployAdapter.s.sol', network, false); // false = only latest broadcast

                console.log('\n📝 Next steps:');
                console.log('   1. Check network-config.ts for the updated adapter address');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Use this adapter in your factoring pool deployments');

                resolve();
            } else {
                reject(new Error(`Adapter deployment failed with exit code ${code}`));
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
async function deployAdapterLauncher(): Promise<void> {
    try {
        // Get network interactively
        const network = await getNetworkInteractive();

        // Get private key interactively
        const privateKey = await getPrivateKeyInteractively();

        await deployAdapterWorkflow(network, privateKey);
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deployAdapterLauncher();
}
