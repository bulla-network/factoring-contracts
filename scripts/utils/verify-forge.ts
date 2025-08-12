import { spawn } from 'child_process';
import { existsSync, readFileSync, readdirSync } from 'fs';
import { join } from 'path';
import { getChainId, getEtherscanApiKey } from '../network-config';

export interface BroadcastTransaction {
    hash: string;
    transactionType: string;
    contractName: string;
    contractAddress: string;
    function: any;
    arguments: any;
}

export interface BroadcastFile {
    transactions: BroadcastTransaction[];
    receipts: any[];
}

/**
 * Reads the latest broadcast file for a given script and network
 * @param scriptName Name of the script (e.g., "DeployBullaFactoring.s.sol")
 * @param network Network name
 * @returns Parsed broadcast data or null if not found
 */
export function readLatestBroadcast(scriptName: string, network: string): BroadcastFile | null {
    try {
        const chainId = getChainId(network);
        const broadcastPath = `broadcast/${scriptName}/${chainId}/run-latest.json`;

        if (!existsSync(broadcastPath)) {
            console.log(`⚠️  No broadcast file found at: ${broadcastPath}`);
            return null;
        }

        const broadcastData = readFileSync(broadcastPath, 'utf8');
        return JSON.parse(broadcastData) as BroadcastFile;
    } catch (error) {
        console.error('❌ Error reading broadcast file:', (error as Error).message);
        return null;
    }
}

/**
 * Reads all broadcast files for a given script and network
 * @param scriptName Name of the script (e.g., "DeployBullaFactoring.s.sol")
 * @param network Network name
 * @returns Array of parsed broadcast data
 */
export function readAllBroadcasts(scriptName: string, network: string): BroadcastFile[] {
    try {
        const chainId = getChainId(network);
        const broadcastDir = `broadcast/${scriptName}/${chainId}`;

        if (!existsSync(broadcastDir)) {
            console.log(`⚠️  No broadcast directory found at: ${broadcastDir}`);
            return [];
        }

        const files = readdirSync(broadcastDir);
        const runFiles = files.filter(file => file.startsWith('run-') && file.endsWith('.json'));

        const broadcasts: BroadcastFile[] = [];

        for (const file of runFiles) {
            try {
                const filePath = join(broadcastDir, file);
                const broadcastData = readFileSync(filePath, 'utf8');
                broadcasts.push(JSON.parse(broadcastData) as BroadcastFile);
            } catch (error) {
                console.log(`⚠️  Error reading broadcast file ${file}:`, (error as Error).message);
            }
        }

        return broadcasts;
    } catch (error) {
        console.error('❌ Error reading broadcast directory:', (error as Error).message);
        return [];
    }
}

/**
 * Verifies a contract using forge verify-contract command
 * @param contractAddress Contract address to verify
 * @param contractPath Contract path in format "contracts/Contract.sol:ContractName"
 * @param network Network name
 * @returns Promise that resolves when verification completes
 */
export function verifyContract(contractAddress: string, contractPath: string, network: string): Promise<void> {
    return new Promise(resolve => {
        // Get network-specific details
        const etherscanApiKey = getEtherscanApiKey(network);
        const chainId = getChainId(network);

        // Build forge verify command (same as bulla-contracts-v2)
        const verifyArgs = [
            'verify-contract',
            contractAddress,
            contractPath,
            '--chain-id',
            chainId.toString(),
            '--etherscan-api-key',
            etherscanApiKey,
            '--compiler-version',
            'v0.8.30+commit.13a70b2a', // Updated to 0.8.30
            '--num-of-optimizations',
            '200',
            '--watch',
        ];

        console.log('\n🔍 Verifying contract on block explorer...');
        console.log(`📄 Contract: ${contractPath}`);
        console.log(`📍 Address: ${contractAddress}`);
        console.log(`🌐 Network: ${network} (Chain ID: ${chainId})`);

        const forgeProcess = spawn('forge', verifyArgs, {
            stdio: 'inherit',
            cwd: process.cwd(),
        });

        forgeProcess.on('close', code => {
            if (code === 0) {
                console.log('✅ Contract verification completed successfully!');
            } else {
                console.error(`❌ Contract verification failed with exit code ${code}`);
            }
            // Always resolve - verification failure shouldn't stop deployment
            resolve();
        });

        forgeProcess.on('error', error => {
            if ((error as any).code === 'ENOENT') {
                console.error('❌ Forge not found. Make sure Foundry is installed and in your PATH.');
            } else {
                console.error('❌ Failed to start forge verify:', error.message);
            }
            // Always resolve - verification failure shouldn't stop deployment
            resolve();
        });
    });
}

/**
 * Verifies all contracts from broadcast files
 * @param scriptName Name of the script (e.g., "DeployBullaFactoring.s.sol")
 * @param network Network name
 * @param allBroadcasts If true, verifies all broadcasts; if false, only latest (default: false)
 * @returns Promise that resolves when all verifications complete
 */
export async function verifyBroadcastContracts(scriptName: string, network: string, allBroadcasts = false): Promise<void> {
    console.log(`\n🔍 Starting contract verification from ${allBroadcasts ? 'all' : 'latest'} broadcast files...`);

    try {
        const broadcasts = allBroadcasts
            ? readAllBroadcasts(scriptName, network)
            : ([readLatestBroadcast(scriptName, network)].filter(Boolean) as BroadcastFile[]);

        if (broadcasts.length === 0) {
            console.log('⚠️  No broadcast data found. Skipping verification.');
            return;
        }

        // Collect all unique contract deployments across all broadcasts
        const allDeployments = new Map<string, { contractName: string; contractAddress: string }>();

        for (const broadcast of broadcasts) {
            const contractDeployments = broadcast.transactions.filter(
                tx => tx.transactionType === 'CREATE' && tx.contractName && tx.contractAddress,
            );

            for (const deployment of contractDeployments) {
                // Use address as key to avoid duplicates
                allDeployments.set(deployment.contractAddress, {
                    contractName: deployment.contractName,
                    contractAddress: deployment.contractAddress,
                });
            }
        }

        if (allDeployments.size === 0) {
            console.log('⚠️  No contract deployments found in broadcast files.');
            return;
        }

        console.log(
            `📋 Found ${allDeployments.size} unique contract(s) to verify${
                allBroadcasts ? ` across ${broadcasts.length} broadcast(s)` : ''
            }:`,
        );

        const deploymentList = Array.from(allDeployments.values());

        for (const deployment of deploymentList) {
            console.log(`   • ${deployment.contractName} at ${deployment.contractAddress}`);
        }

        // Verify each unique contract
        for (const deployment of deploymentList) {
            const contractPath = getContractPath(deployment.contractName);
            if (contractPath) {
                await verifyContract(deployment.contractAddress, contractPath, network);
            } else {
                console.log(`⚠️  Unknown contract path for: ${deployment.contractName}`);
            }
        }

        console.log('✅ Contract verification process completed!');
    } catch (error) {
        console.error('❌ Error during contract verification:', (error as Error).message);
        console.log('ℹ️  You can verify contracts manually later if needed');
    }
}

/**
 * Maps contract names to their full paths
 * @param contractName Name of the contract
 * @returns Full contract path or null if unknown
 */
function getContractPath(contractName: string): string | null {
    const contractPaths: Record<string, string> = {
        BullaFactoringV2: 'contracts/BullaFactoring.sol:BullaFactoringV2',
        BullaClaimV2InvoiceProviderAdapterV2: 'contracts/BullaClaimV2InvoiceProviderAdapterV2.sol:BullaClaimV2InvoiceProviderAdapterV2',
        BullaClaimV1InvoiceProviderAdapterV2: 'contracts/BullaClaimV1InvoiceProviderAdapterV2.sol:BullaClaimV1InvoiceProviderAdapterV2',
        DepositPermissions: 'contracts/DepositPermissions.sol:DepositPermissions',
        FactoringPermissions: 'contracts/FactoringPermissions.sol:FactoringPermissions',
        Permissions: 'contracts/Permissions.sol:Permissions',
        RedemptionQueue: 'contracts/RedemptionQueue.sol:RedemptionQueue',
        FactoringFundManager: 'contracts/FactoringFundManager.sol:FactoringFundManager',
    };

    return contractPaths[contractName] || null;
}
