import { verifyBroadcastContracts } from './utils/verify-forge';
import { getNetworkInteractive } from './utils/interactive-prompt';

const FACTORY_SCRIPT_NAME = 'DeployBullaFactoringFactory.s.sol';

/**
 * Verify factory contracts workflow
 */
export async function verifyFactoryWorkflow(network: string): Promise<void> {
    console.log(`🔍 Verifying BullaFactoringFactoryV2_1 contracts on ${network}...\n`);

    try {
        await verifyBroadcastContracts(FACTORY_SCRIPT_NAME, network, false);
        console.log('\n✅ Factory verification completed!');
    } catch (error) {
        console.error('❌ Verification error:', (error as Error).message);
        throw error;
    }
}

/**
 * Launcher: Get network interactively or from env, then run workflow
 */
async function verifyFactoryLauncher(): Promise<void> {
    try {
        // Check for network from environment or get interactively
        let network = process.env.NETWORK;

        if (!network) {
            network = await getNetworkInteractive();
        } else {
            console.log(`🎯 Using network from environment: ${network}`);
        }

        await verifyFactoryWorkflow(network);
    } catch (error) {
        console.error('❌ Verification failed:', (error as Error).message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    // Handle Ctrl+C gracefully
    process.on('SIGINT', () => {
        console.log('\n\n⚠️  Verification interrupted by user');
        process.exit(0);
    });

    verifyFactoryLauncher();
}
