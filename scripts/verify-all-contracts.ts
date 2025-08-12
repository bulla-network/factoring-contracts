import { readdirSync, statSync } from 'fs';
import { join } from 'path';
import { verifyBroadcastContracts } from './utils/verify-forge';

/**
 * Get network name from chain ID
 */
function getNetworkFromChainId(chainId: string): string | null {
    const chainIdMap: Record<string, string> = {
        '1': 'mainnet',
        '137': 'polygon',
        '11155111': 'sepolia', // Also used for fundora-sepolia
    };
    return chainIdMap[chainId] || null;
}

/**
 * Recursively find all broadcast directories
 */
function findBroadcastDirectories(broadcastPath: string): Array<{ script: string; chainId: string; network: string }> {
    const results: Array<{ script: string; chainId: string; network: string }> = [];

    try {
        if (!statSync(broadcastPath).isDirectory()) {
            return results;
        }

        const scriptDirs = readdirSync(broadcastPath);

        for (const scriptDir of scriptDirs) {
            const scriptPath = join(broadcastPath, scriptDir);

            if (statSync(scriptPath).isDirectory()) {
                // Check for chain ID subdirectories
                const chainDirs = readdirSync(scriptPath);

                for (const chainDir of chainDirs) {
                    const chainPath = join(scriptPath, chainDir);

                    if (statSync(chainPath).isDirectory()) {
                        const network = getNetworkFromChainId(chainDir);
                        if (network) {
                            // Check if run-latest.json exists
                            const runLatestPath = join(chainPath, 'run-latest.json');
                            try {
                                if (statSync(runLatestPath).isFile()) {
                                    results.push({
                                        script: scriptDir,
                                        chainId: chainDir,
                                        network: network,
                                    });
                                }
                            } catch {
                                // run-latest.json doesn't exist, skip
                            }
                        } else {
                            console.log(`⚠️  Unknown chain ID: ${chainDir}`);
                        }
                    }
                }
            }
        }
    } catch (error) {
        console.error('❌ Error reading broadcast directories:', (error as Error).message);
    }

    return results;
}

/**
 * Main verification function
 */
async function verifyAllContracts(): Promise<void> {
    console.log('🔍 Scanning for deployed contracts to verify...\n');

    const broadcastPath = 'broadcast';
    const deployments = findBroadcastDirectories(broadcastPath);

    if (deployments.length === 0) {
        console.log('⚠️  No deployments found in broadcast folder.');
        console.log('   Make sure you have run deployments with --broadcast flag.');
        return;
    }

    console.log(`📋 Found ${deployments.length} deployment(s) to verify:\n`);

    for (const deployment of deployments) {
        console.log(`📄 Script: ${deployment.script}`);
        console.log(`🌐 Network: ${deployment.network} (Chain ID: ${deployment.chainId})`);
        console.log('─'.repeat(50));
    }

    console.log('\n🚀 Starting verification process...\n');

    // Verify each deployment
    for (let i = 0; i < deployments.length; i++) {
        const deployment = deployments[i];

        console.log(`\n📝 [${i + 1}/${deployments.length}] Verifying ${deployment.script} on ${deployment.network}...`);

        try {
            await verifyBroadcastContracts(deployment.script, deployment.network, true); // true = verify all broadcasts
        } catch (error) {
            console.error(`❌ Error verifying ${deployment.script}:`, (error as Error).message);
        }

        // Add a small delay between verifications to avoid rate limiting
        if (i < deployments.length - 1) {
            console.log('\n⏳ Waiting 2 seconds before next verification...');
            await new Promise(resolve => setTimeout(resolve, 2000));
        }
    }

    console.log('\n✅ Verification process completed!');
    console.log('\n📝 Summary:');
    console.log(`   • Processed ${deployments.length} deployment(s)`);
    console.log('   • Check the output above for individual verification results');
    console.log('   • Verification failures are non-critical and can be retried');
}

/**
 * Enhanced verification for specific network
 */
async function verifyNetworkContracts(targetNetwork: string): Promise<void> {
    console.log(`🔍 Verifying all contracts for network: ${targetNetwork}\n`);

    const broadcastPath = 'broadcast';
    const deployments = findBroadcastDirectories(broadcastPath).filter(
        deployment => deployment.network === targetNetwork || (targetNetwork === 'fundora-sepolia' && deployment.network === 'sepolia'),
    );

    if (deployments.length === 0) {
        console.log(`⚠️  No deployments found for network: ${targetNetwork}`);
        return;
    }

    console.log(`📋 Found ${deployments.length} deployment(s) for ${targetNetwork}:\n`);

    for (const deployment of deployments) {
        console.log(`📄 ${deployment.script}`);
        try {
            await verifyBroadcastContracts(deployment.script, targetNetwork === 'fundora-sepolia' ? 'sepolia' : deployment.network, true); // true = verify all broadcasts
        } catch (error) {
            console.error(`❌ Error verifying ${deployment.script}:`, (error as Error).message);
        }
    }
}

// Main execution
async function main(): Promise<void> {
    try {
        const targetNetwork = process.env.NETWORK;

        if (targetNetwork) {
            console.log(`🎯 Target network specified: ${targetNetwork}`);
            await verifyNetworkContracts(targetNetwork);
        } else {
            console.log('🌐 No target network specified, verifying all deployments...');
            await verifyAllContracts();
        }
    } catch (error) {
        console.error('❌ Verification script failed:', (error as Error).message);
        process.exit(1);
    }
}

// Handle Ctrl+C gracefully
process.on('SIGINT', () => {
    console.log('\n\n⚠️  Verification interrupted by user');
    process.exit(0);
});

// Run the script
main();
