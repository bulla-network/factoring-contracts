import { getConfig, getRpcUrl, PoolName } from './network-config';
import { runPreDeployChecks } from './predeploy-checks';
import { buildFactoringEnv } from './utils/factoring-env';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkAndPoolInteractive } from './utils/interactive-prompt';
import { updateFactoringFromBroadcast } from './utils/update-config';
import { verifyBroadcastContracts } from './utils/verify-forge';

/**
 * Deploy factoring workflow (can be called with parameters or standalone)
 */
export async function deployFactoringWorkflow(network: string, pool: PoolName, privateKey: string): Promise<void> {
    console.log(`🚀 Deploying BullaFactoring contracts to ${network}/${pool}...\n`);

    // Get full configuration
    const config = getConfig(network, pool);

    // Display deployment info
    console.log('📋 Deployment Configuration:');
    console.log(`   Network: ${network}`);
    console.log(`   Pool: ${pool}`);
    console.log(`   Pool Display Name: ${config.poolDisplayName}`);
    console.log(`   Token Name: ${config.poolTokenName}`);
    console.log(`   Token Symbol: ${config.poolTokenSymbol}`);
    console.log(`   Protocol Fee: ${config.protocolFeeBps} bps`);
    console.log(`   Admin Fee: ${config.adminFeeBps} bps`);
    console.log(`   Target Yield: ${config.targetYieldBps} bps`);
    console.log(`   Insurance Fee: ${config.insuranceFeeBps ?? 'script default (100)'} bps\n`);

    console.log(`📡 Starting deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Pre-deployment checks (spec: bulla-specs deploy-pool.md, POOLDEPLOY). Throws if any check fails,
    // so nothing is broadcast. There is intentionally no skip flag.
    await runPreDeployChecks(network, pool);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        ...buildFactoringEnv(config, network),
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript('script/DeployBullaFactoring.s.sol:DeployBullaFactoring', rpcUrl, privateKey, env, network);

        // Handle forge process events with verification
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Deployment completed successfully!');
                console.log(`🎉 Your BullaFactoring contracts are now live on ${network}/${pool}!`);

                // Update network config with new deployment addresses
                console.log('\n📝 Updating network-config.ts...');
                updateFactoringFromBroadcast('DeployBullaFactoring.s.sol', network, pool);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployBullaFactoring.s.sol', network, false); // false = only latest broadcast

                console.log('\n📝 Next steps:');
                console.log('   1. Check network-config.ts for updated deployment addresses');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Set up permissions and whitelist callbacks');

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
 * Launcher: Get network, pool, and private key interactively, then run workflow
 */
async function deployFactoringLauncher(): Promise<void> {
    try {
        // Get network and pool interactively
        const { network, pool } = await getNetworkAndPoolInteractive();

        // Get private key interactively
        const privateKey = await getPrivateKeyInteractively();

        await deployFactoringWorkflow(network, pool, privateKey);
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deployFactoringLauncher();
}
