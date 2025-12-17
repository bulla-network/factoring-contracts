import * as readline from 'readline';
import { getConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkAndPoolInteractive } from './utils/interactive-prompt';
import { verifyBroadcastContracts } from './utils/verify-forge';

async function promptForAmount(defaultAmount: number): Promise<number> {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });

    return new Promise(resolve => {
        rl.question(`Enter impair reserve amount (default: ${defaultAmount}): `, answer => {
            rl.close();
            const amount = answer.trim();
            if (amount === '' || amount === undefined) {
                resolve(defaultAmount);
            } else {
                const parsedAmount = parseInt(amount, 10);
                if (isNaN(parsedAmount) || parsedAmount < 0) {
                    console.log(`Invalid amount "${amount}". Using default: ${defaultAmount}`);
                    resolve(defaultAmount);
                } else {
                    resolve(parsedAmount);
                }
            }
        });
    });
}

async function setImpairReserve(): Promise<void> {
    try {
        // Get network and pool interactively
        const { network, pool } = await getNetworkAndPoolInteractive();

        console.log(`🔧 Setting impair reserve on ${network}/${pool}...\n`);

        // Get full configuration
        const config = getConfig(network, pool);

        // Check if BullaFactoring address is available
        if (!config.bullaFactoringAddress) {
            throw new Error(`BullaFactoring address not found for ${network} network. Please deploy BullaFactoring first.`);
        }

        console.log('📋 Configuration:');
        console.log(`   Network: ${network}`);
        console.log(`   Pool: ${pool}`);
        console.log(`   Pool Display Name: ${config.poolDisplayName}`);
        console.log(`   BullaFactoring: ${config.bullaFactoringAddress || 'Not deployed'}`);

        // Prompt for impair reserve amount
        const defaultAmount = 5000;
        const impairReserveAmount = await promptForAmount(defaultAmount);

        console.log(`\n💰 Setting impair reserve to: ${impairReserveAmount}`);

        // Get private key interactively
        const formattedPrivateKey = await getPrivateKeyInteractively();

        console.log(`\n📡 Starting impair reserve update on ${network}...\n`);

        // Get RPC URL using shared config
        const rpcUrl = getRpcUrl(network);

        // Set environment variables for the forge script
        const env: NodeJS.ProcessEnv = {
            ...process.env,
            NETWORK: network,
            PRIVATE_KEY: formattedPrivateKey,
            DEPLOY_PK: formattedPrivateKey,
            BULLA_FACTORING_ADDRESS: config.bullaFactoringAddress,
            IMPAIR_RESERVE_AMOUNT: impairReserveAmount.toString(),
        };

        // Run forge script
        const forgeProcess = runForgeScript('script/SetImpairReserve.s.sol:SetImpairReserve', rpcUrl, formattedPrivateKey, env, network);

        // Handle forge process events
        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Impair reserve set successfully!');
                console.log(`🎉 Impair reserve is now set to ${impairReserveAmount} on ${network}!`);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('SetImpairReserve.s.sol', network, false);

                console.log('\n📝 Next steps:');
                console.log('   1. Check broadcast files for transaction details');
                console.log('   2. Contract interaction has been verified automatically');
                console.log('   3. Impair reserve is now active on the contract');
            } else {
                console.error(`\n❌ Setting impair reserve failed with exit code ${code}`);
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
        console.error('❌ Error setting impair reserve:', error.message);
        process.exit(1);
    }
}

// Setup graceful exit handling
setupGracefulExit();

// Run the script
setImpairReserve();
