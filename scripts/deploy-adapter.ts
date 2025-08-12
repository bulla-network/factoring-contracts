import { getNetworkConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit, validateNetwork } from './utils/interactive-deploy';
import { verifyBroadcastContracts } from './utils/verify-forge';

async function deployAdapter(): Promise<void> {
    try {
        // Get and validate network
        const network = validateNetwork(process.env.NETWORK);

        console.log(`🚀 Deploying BullaClaimV2InvoiceProviderAdapterV2 to ${network} network...\n`);

        // Get network configuration using shared config
        const config = getNetworkConfig(network);

        // Display deployment info
        console.log('📋 Deployment Configuration:');
        console.log(`   BullaClaim: ${config.bullaClaim}`);
        console.log(`   BullaFrendLend: ${config.bullaFrendLendAddress || 'Not set'}`);
        console.log(`   BullaInvoice: ${config.bullaInvoiceAddress || 'Not set'}\n`);

        // Get private key interactively
        const formattedPrivateKey = await getPrivateKeyInteractively();

        console.log(`📡 Starting adapter deployment to ${network}...\n`);

        // Get RPC URL using shared config
        const rpcUrl = getRpcUrl(network);

        // Set environment variables for the deployment script
        const env: NodeJS.ProcessEnv = {
            ...process.env,
            NETWORK: network,
            PRIVATE_KEY: formattedPrivateKey,
            DEPLOY_PK: formattedPrivateKey,
            // Adapter-specific config
            BULLA_CLAIM: config.bullaClaim,
            BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress || '0x0000000000000000000000000000000000000000',
            BULLA_INVOICE_ADDRESS: config.bullaInvoiceAddress || '0x0000000000000000000000000000000000000000',
        };

        // Run forge script
        const forgeProcess = runForgeScript('script/DeployAdapter.s.sol:DeployAdapter', rpcUrl, formattedPrivateKey, env, network);

        // Handle forge process events with verification
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Adapter deployment completed successfully!');
                console.log(`🎉 Your BullaClaimV2InvoiceProviderAdapterV2 is now live on ${network}!`);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployAdapter.s.sol', network, false); // false = only latest broadcast

                console.log('\n📝 Next steps:');
                console.log('   1. Check addresses.json for the deployed adapter address');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Use this adapter address in your main factoring deployment');
            } else {
                console.error(`\n❌ Adapter deployment failed with exit code ${code}`);
                process.exit(code || 1);
            }
        });

        forgeProcess.on('error', error => {
            if ((error as any).code === 'ENOENT') {
                console.error('❌ Forge not found. Make sure Foundry is installed and in your PATH.');
                console.error('   Install from: https://getfoundry.sh/');
            } else {
                console.error('❌ Failed to start forge:', error.message);
            }
            process.exit(1);
        });
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Setup graceful exit handling
setupGracefulExit();

// Run the deployment
deployAdapter();
