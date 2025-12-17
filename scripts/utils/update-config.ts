import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { PoolName } from '../network-config';

/**
 * Read the latest broadcast file for a script
 */
function readLatestBroadcast(scriptName: string, network: string): any {
    const broadcastPath = join('broadcast', scriptName, getChainIdForNetwork(network), 'run-latest.json');
    try {
        const content = readFileSync(broadcastPath, 'utf-8');
        return JSON.parse(content);
    } catch (error) {
        console.error(`Failed to read broadcast file: ${broadcastPath}`);
        throw error;
    }
}

/**
 * Get chain ID for network
 */
function getChainIdForNetwork(network: string): string {
    const chainIds: Record<string, string> = {
        sepolia: '11155111',
        polygon: '137',
        mainnet: '1',
        base: '8453',
    };
    return chainIds[network] || '11155111';
}

/**
 * Extract deployed contract address from broadcast
 */
function extractDeployedAddress(broadcast: any, contractName: string): string | undefined {
    const transactions = broadcast.transactions || [];

    for (const tx of transactions) {
        if (tx.transactionType === 'CREATE' && tx.contractName === contractName) {
            return tx.contractAddress;
        }
    }

    return undefined;
}

/**
 * Update adapter address in network config
 */
export function updateAdapterAddress(network: string, adapterAddress: string): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    // Find the network config section and update the adapter address
    const networkPattern = new RegExp(`(${network}:\\s*{[^}]*BullaClaimInvoiceProviderAdapterAddress:\\s*)'[^']*'`, 's');

    if (networkPattern.test(content)) {
        content = content.replace(networkPattern, `$1'${adapterAddress}'`);
        console.log(`✅ Updated BullaClaimInvoiceProviderAdapterAddress for ${network}: ${adapterAddress}`);
    } else {
        // If it doesn't exist, add it
        const networkSectionPattern = new RegExp(`(${network}:\\s*{[^}]*bullaInvoiceAddress:\\s*'[^']*',)`, 's');

        if (networkSectionPattern.test(content)) {
            content = content.replace(networkSectionPattern, `$1\n        BullaClaimInvoiceProviderAdapterAddress: '${adapterAddress}',`);
            console.log(`✅ Added BullaClaimInvoiceProviderAdapterAddress for ${network}: ${adapterAddress}`);
        } else {
            console.warn(`⚠️  Could not find ${network} network config to update`);
            return;
        }
    }

    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Update deployed pool addresses in network config
 */
export function updatePoolDeployment(
    network: string,
    pool: PoolName,
    addresses: {
        bullaFactoringAddress?: string;
        factoringPermissionsAddress?: string;
        depositPermissionsAddress?: string;
        redeemPermissionsAddress?: string;
    },
): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    // Find the deployment config for this network + pool
    // This pattern captures everything inside the return {} block for the specific network/pool combination
    const deploymentPattern = new RegExp(
        `(case\\s+'${network}':[\\s\\S]*?case\\s+'${pool}':[\\s\\S]*?return\\s*\\{)([\\s\\S]*?)(\\};)`,
        '',
    );

    const match = content.match(deploymentPattern);
    if (!match) {
        console.warn(`⚠️  Could not find deployment config for ${network}/${pool}`);
        console.warn(`   Tried pattern: case '${network}': ... case '${pool}': ... return { ... };`);
        return;
    }

    let deploymentConfig = match[2];

    // Update each address if provided
    Object.entries(addresses).forEach(([key, value]) => {
        if (value) {
            const addressPattern = new RegExp(`${key}:\\s*'[^']*'`);
            if (addressPattern.test(deploymentConfig)) {
                deploymentConfig = deploymentConfig.replace(addressPattern, `${key}: '${value}'`);
                console.log(`✅ Updated ${key} for ${network}/${pool}: ${value}`);
            } else {
                // Add the address before writeNewAddresses
                const writeNewAddressesPattern = /(writeNewAddresses:)/;
                if (writeNewAddressesPattern.test(deploymentConfig)) {
                    deploymentConfig = deploymentConfig.replace(
                        writeNewAddressesPattern,
                        `${key}: '${value}',\n                        $1`,
                    );
                    console.log(`✅ Added ${key} for ${network}/${pool}: ${value}`);
                }
            }
        }
    });

    content = content.replace(match[0], `${match[1]}${deploymentConfig}${match[3]}`);
    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Extract adapter address from broadcast and update config
 */
export function updateAdapterFromBroadcast(scriptName: string, network: string): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);
        const adapterAddress = extractDeployedAddress(broadcast, 'BullaClaimV2InvoiceProviderAdapterV2');

        if (adapterAddress) {
            updateAdapterAddress(network, adapterAddress);
        } else {
            console.warn('⚠️  Could not find adapter address in broadcast');
        }
    } catch (error) {
        console.error('❌ Error updating adapter address:', (error as Error).message);
    }
}

/**
 * Extract factoring addresses from broadcast and update config
 */
export function updateFactoringFromBroadcast(scriptName: string, network: string, pool: PoolName): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);

        const addresses = {
            bullaFactoringAddress: extractDeployedAddress(broadcast, 'BullaFactoringV2_1'),
            factoringPermissionsAddress: extractDeployedAddress(broadcast, 'FactoringPermissions'),
            depositPermissionsAddress: extractDeployedAddress(broadcast, 'DepositPermissions'),
            redeemPermissionsAddress: extractDeployedAddress(broadcast, 'RedemptionQueue'),
        };

        updatePoolDeployment(network, pool, addresses);
    } catch (error) {
        console.error('❌ Error updating factoring addresses:', (error as Error).message);
    }
}
