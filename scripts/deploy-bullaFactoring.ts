import { getNetworkConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit, validateNetwork } from './utils/interactive-deploy';
import { verifyBroadcastContracts } from './utils/verify-forge';

async function deployContracts(): Promise<void> {
    try {
        // Get and validate network
        const network = validateNetwork(process.env.NETWORK);

        console.log(`🚀 Deploying BullaFactoring contracts to ${network} network...\n`);

        // Get network configuration using shared config
        const config = getNetworkConfig(network);

        // Display deployment info
        console.log('📋 Deployment Configuration:');
        console.log(`   Pool Name: ${config.poolName}`);
        console.log(`   Token Symbol: ${config.poolTokenSymbol}`);
        console.log(`   Protocol Fee: ${config.protocolFeeBps} bps`);
        console.log(`   Admin Fee: ${config.adminFeeBps} bps`);
        console.log(`   Target Yield: ${config.targetYieldBps} bps\n`);

        // Get private key interactively
        const formattedPrivateKey = await getPrivateKeyInteractively();

        console.log(`📡 Starting deployment to ${network}...\n`);

        // Get RPC URL using shared config
        const rpcUrl = getRpcUrl(network);

        // Set environment variables for the deployment script
        const env: NodeJS.ProcessEnv = {
            ...process.env,
            NETWORK: network,
            PRIVATE_KEY: formattedPrivateKey,
            DEPLOY_PK: formattedPrivateKey,
            // Network-specific config
            BULLA_CLAIM: config.bullaClaim,
            UNDERLYING_ASSET: config.underlyingAsset,
            UNDERWRITER: config.underwriter,
            BULLA_DAO: config.bullaDao,
            PROTOCOL_FEE_BPS: config.protocolFeeBps.toString(),
            ADMIN_FEE_BPS: config.adminFeeBps.toString(),
            POOL_NAME: config.poolName,
            TARGET_YIELD_BPS: config.targetYieldBps.toString(),
            POOL_TOKEN_NAME: config.poolTokenName,
            POOL_TOKEN_SYMBOL: config.poolTokenSymbol,
            BULLA_CLAIM_INVOICE_PROVIDER_ADAPTER_ADDRESS: config.BullaClaimInvoiceProviderAdapterAddress || '',
            FACTORING_PERMISSIONS_ADDRESS: config.factoringPermissionsAddress || '',
            DEPOSIT_PERMISSIONS_ADDRESS: config.depositPermissionsAddress || '',
            REDEEM_PERMISSIONS_ADDRESS: config.redeemPermissionsAddress || '',
            BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress || '',
            BULLA_INVOICE_ADDRESS: config.bullaInvoiceAddress || '',
            BULLA_FACTORING_ADDRESS: config.bullaFactoringAddress || '',
        };

        // Run forge script
        const forgeProcess = runForgeScript(
            'script/DeployBullaFactoring.s.sol:DeployBullaFactoring',
            rpcUrl,
            formattedPrivateKey,
            env,
            network,
        );

        // Handle forge process events with verification
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Deployment completed successfully!');
                console.log(`🎉 Your BullaFactoring contracts are now live on ${network}!`);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployBullaFactoring.s.sol', network, false); // false = only latest broadcast

                console.log('\n📝 Next steps:');
                console.log('   1. Check addresses.json for deployed contract addresses');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Set up permissions and initial configurations');
            } else {
                console.error(`\n❌ Deployment failed with exit code ${code}`);
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
deployContracts();
