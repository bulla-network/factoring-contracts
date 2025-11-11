import { getNetworkConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit, validateNetwork } from './utils/interactive-deploy';

async function whitelistCallback(): Promise<void> {
    try {
        // Get and validate network
        const network = validateNetwork(process.env.NETWORK);

        console.log(`🔑 Whitelisting callback for BullaFactoring on ${network} network...\n`);

        // Get network configuration using shared config
        const config = getNetworkConfig(network);

        // Validate required addresses
        if (!config.bullaFrendLendAddress || config.bullaFrendLendAddress === '0x0000000000000000000000000000000000000000') {
            throw new Error(`BullaFrendLend address not configured for ${network} network`);
        }

        if (!config.bullaFactoringAddress || config.bullaFactoringAddress === '0x0000000000000000000000000000000000000000') {
            throw new Error(`BullaFactoring address not configured for ${network} network`);
        }

        if (!config.bullaClaim || config.bullaClaim === '0x0000000000000000000000000000000000000000') {
            throw new Error(`BullaClaimV2 address not configured for ${network} network`);
        }

        // Display configuration info
        console.log('📋 Whitelist Configuration:');
        console.log(`   Network: ${network}`);
        console.log(`   Pool Name: ${config.poolName}`);
        console.log(`   BullaFrendLend: ${config.bullaFrendLendAddress}`);
        console.log(`   BullaClaimV2: ${config.bullaClaim}`);
        console.log(`   BullaFactoring: ${config.bullaFactoringAddress}`);
        console.log(`   Callback Functions: onLoanOfferAccepted, reconcileSingleInvoice\n`);

        // Get private key interactively
        const formattedPrivateKey = await getPrivateKeyInteractively();

        console.log(`📡 Starting callback whitelisting on ${network}...\n`);

        // Get RPC URL using shared config
        const rpcUrl = getRpcUrl(network);

        // Set environment variables for the script
        const env: NodeJS.ProcessEnv = {
            ...process.env,
            NETWORK: network,
            PRIVATE_KEY: formattedPrivateKey,
            BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress,
            BULLA_FACTORING_ADDRESS: config.bullaFactoringAddress,
            BULLA_CLAIM_V2_ADDRESS: config.bullaClaim,
        };

        // Run forge script
        const forgeProcess = runForgeScript('script/WhitelistCallback.s.sol:WhitelistCallback', rpcUrl, formattedPrivateKey, env, network);

        // Handle forge process events
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Callback whitelisting completed successfully!');
                console.log(`🎉 BullaFactoring callbacks are now whitelisted!`);

                console.log('\n📝 What this enables:');
                console.log('   ✓ BullaFactoring can now call offerLoan() without CallbackNotWhitelisted error');
                console.log('   ✓ When loan offers are accepted, onLoanOfferAccepted() will be called back on BullaFrendLend');
                console.log('   ✓ When BullaClaimV2 invoices are paid, reconcileSingleInvoice() will be called back');
                console.log('   ✓ The factoring pool can now issue loan offers and handle paid invoice callbacks');
            } else {
                console.error(`\n❌ Callback whitelisting failed with exit code ${code}`);
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
        console.error('❌ Whitelisting error:', error.message);
        process.exit(1);
    }
}

// Setup graceful exit handling
setupGracefulExit();

// Run the whitelisting
whitelistCallback();
