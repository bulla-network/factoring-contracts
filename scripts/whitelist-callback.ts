import { getConfig, getRpcUrl, PoolName } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkAndPoolInteractive } from './utils/interactive-prompt';

/**
 * Whitelist callback workflow (can be called with parameters or standalone)
 */
export async function whitelistCallbackWorkflow(network: string, pool: PoolName, privateKey: string): Promise<void> {
    console.log(`🔑 Whitelisting callback for BullaFactoring on ${network}/${pool}...\n`);

    // Get full configuration
    const config = getConfig(network, pool);

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
    console.log(`   Pool: ${pool}`);
    console.log(`   Pool Display Name: ${config.poolDisplayName}`);
    console.log(`   BullaFrendLend: ${config.bullaFrendLendAddress}`);
    console.log(`   BullaClaimV2: ${config.bullaClaim}`);
    console.log(`   BullaFactoring: ${config.bullaFactoringAddress || 'Not deployed'}`);
    console.log(`   Callback Functions: onLoanOfferAccepted, reconcileSingleInvoice\n`);

    console.log(`📡 Starting callback whitelisting on ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress,
        BULLA_FACTORING_ADDRESS: config.bullaFactoringAddress,
        BULLA_CLAIM_V2_ADDRESS: config.bullaClaim,
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript('script/WhitelistCallback.s.sol:WhitelistCallback', rpcUrl, privateKey, env, network);

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

                resolve();
            } else {
                reject(new Error(`Callback whitelisting failed with exit code ${code}`));
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
 * Launcher: Get network, pool, and private key interactively, then run workflow
 */
async function whitelistCallbackLauncher(): Promise<void> {
    try {
        // Get network and pool interactively
        const { network, pool } = await getNetworkAndPoolInteractive();

        // Get private key interactively
        const privateKey = await getPrivateKeyInteractively();

        await whitelistCallbackWorkflow(network, pool, privateKey);
    } catch (error: any) {
        console.error('❌ Whitelisting error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    whitelistCallbackLauncher();
}
