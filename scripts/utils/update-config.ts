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
        arbitrum: '42161',
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
 * Update SumSub KYC Issuer address in network config
 */
export function updateSumsubKycIssuerAddress(network: string, issuerAddress: string): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    // Find the network config section and update the issuer address
    const networkPattern = new RegExp(`(${network}:\\s*{[^}]*sumsubKycIssuerAddress:\\s*)'[^']*'`, 's');

    if (networkPattern.test(content)) {
        content = content.replace(networkPattern, `$1'${issuerAddress}'`);
        console.log(`✅ Updated sumsubKycIssuerAddress for ${network}: ${issuerAddress}`);
    } else {
        // If it doesn't exist, add it after BullaClaimInvoiceProviderAdapterAddress (or bullaInvoiceAddress as fallback)
        const afterAdapterPattern = new RegExp(
            `(${network}:\\s*{[^}]*BullaClaimInvoiceProviderAdapterAddress:\\s*'[^']*',)`,
            's',
        );
        const afterInvoicePattern = new RegExp(`(${network}:\\s*{[^}]*bullaInvoiceAddress:\\s*'[^']*',)`, 's');

        if (afterAdapterPattern.test(content)) {
            content = content.replace(afterAdapterPattern, `$1\n        sumsubKycIssuerAddress: '${issuerAddress}',`);
            console.log(`✅ Added sumsubKycIssuerAddress for ${network}: ${issuerAddress}`);
        } else if (afterInvoicePattern.test(content)) {
            content = content.replace(afterInvoicePattern, `$1\n        sumsubKycIssuerAddress: '${issuerAddress}',`);
            console.log(`✅ Added sumsubKycIssuerAddress for ${network}: ${issuerAddress}`);
        } else {
            console.warn(`⚠️  Could not find ${network} network config to update`);
            return;
        }
    }

    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Extract SumSub KYC Issuer address from broadcast and update config
 */
export function updateSumsubKycIssuerFromBroadcast(scriptName: string, network: string): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);
        const issuerAddress = extractDeployedAddress(broadcast, 'SumsubKycIssuer');

        if (issuerAddress) {
            updateSumsubKycIssuerAddress(network, issuerAddress);
        } else {
            console.warn('⚠️  Could not find SumsubKycIssuer address in broadcast');
        }
    } catch (error) {
        console.error('❌ Error updating SumsubKycIssuer address:', (error as Error).message);
    }
}

/**
 * Update AgreementSignatureRepo address in network config
 */
export function updateAgreementSignatureRepoAddress(network: string, repoAddress: string): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    // Find the network config section and update the repo address
    const networkPattern = new RegExp(`(${network}:\\s*{[^}]*agreementSignatureRepoAddress:\\s*)'[^']*'`, 's');

    if (networkPattern.test(content)) {
        content = content.replace(networkPattern, `$1'${repoAddress}'`);
        console.log(`✅ Updated agreementSignatureRepoAddress for ${network}: ${repoAddress}`);
    } else {
        // If it doesn't exist, add it after sumsubKycIssuerAddress (or BullaClaimInvoiceProviderAdapterAddress as fallback)
        const afterSumsubPattern = new RegExp(
            `(${network}:\\s*{[^}]*sumsubKycIssuerAddress:\\s*'[^']*',)`,
            's',
        );
        const afterAdapterPattern = new RegExp(
            `(${network}:\\s*{[^}]*BullaClaimInvoiceProviderAdapterAddress:\\s*'[^']*',)`,
            's',
        );

        if (afterSumsubPattern.test(content)) {
            content = content.replace(afterSumsubPattern, `$1\n        agreementSignatureRepoAddress: '${repoAddress}',`);
            console.log(`✅ Added agreementSignatureRepoAddress for ${network}: ${repoAddress}`);
        } else if (afterAdapterPattern.test(content)) {
            content = content.replace(afterAdapterPattern, `$1\n        agreementSignatureRepoAddress: '${repoAddress}',`);
            console.log(`✅ Added agreementSignatureRepoAddress for ${network}: ${repoAddress}`);
        } else {
            console.warn(`⚠️  Could not find ${network} network config to update`);
            return;
        }
    }

    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Extract AgreementSignatureRepo address from broadcast and update config
 */
export function updateAgreementSignatureRepoFromBroadcast(scriptName: string, network: string): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);
        const repoAddress = extractDeployedAddress(broadcast, 'AgreementSignatureRepo');

        if (repoAddress) {
            updateAgreementSignatureRepoAddress(network, repoAddress);
        } else {
            console.warn('⚠️  Could not find AgreementSignatureRepo address in broadcast');
        }
    } catch (error) {
        console.error('❌ Error updating AgreementSignatureRepo address:', (error as Error).message);
    }
}

/**
 * Update BullaKycGate address in network config
 */
export function updateBullaKycGateAddress(network: string, gateAddress: string): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    const networkPattern = new RegExp(`(${network}:\\s*{[^}]*bullaKycGateAddress:\\s*)'[^']*'`, 's');

    if (networkPattern.test(content)) {
        content = content.replace(networkPattern, `$1'${gateAddress}'`);
        console.log(`✅ Updated bullaKycGateAddress for ${network}: ${gateAddress}`);
    } else {
        const afterAgreementPattern = new RegExp(
            `(${network}:\\s*{[^}]*agreementSignatureRepoAddress:\\s*'[^']*',)`,
            's',
        );
        const afterSumsubPattern = new RegExp(
            `(${network}:\\s*{[^}]*sumsubKycIssuerAddress:\\s*'[^']*',)`,
            's',
        );

        if (afterAgreementPattern.test(content)) {
            content = content.replace(afterAgreementPattern, `$1\n        bullaKycGateAddress: '${gateAddress}',`);
            console.log(`✅ Added bullaKycGateAddress for ${network}: ${gateAddress}`);
        } else if (afterSumsubPattern.test(content)) {
            content = content.replace(afterSumsubPattern, `$1\n        bullaKycGateAddress: '${gateAddress}',`);
            console.log(`✅ Added bullaKycGateAddress for ${network}: ${gateAddress}`);
        } else {
            console.warn(`⚠️  Could not find ${network} network config to update`);
            return;
        }
    }

    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Extract BullaKycGate address from broadcast and update config
 */
export function updateBullaKycGateFromBroadcast(scriptName: string, network: string): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);
        const gateAddress = extractDeployedAddress(broadcast, 'BullaKycGate');

        if (gateAddress) {
            updateBullaKycGateAddress(network, gateAddress);
        } else {
            console.log('ℹ️  No BullaKycGate in broadcast (likely using existing deployment)');
        }
    } catch (error) {
        console.error('❌ Error updating BullaKycGate address:', (error as Error).message);
    }
}

/**
 * Update ComplianceDepositPermissions address in network config
 */
export function updateComplianceDepositPermissionsAddress(network: string, permissionsAddress: string): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    const networkPattern = new RegExp(
        `(${network}:\\s*{[^}]*complianceDepositPermissionsAddress:\\s*)'[^']*'`,
        's',
    );

    if (networkPattern.test(content)) {
        content = content.replace(networkPattern, `$1'${permissionsAddress}'`);
        console.log(`✅ Updated complianceDepositPermissionsAddress for ${network}: ${permissionsAddress}`);
    } else {
        const afterGatePattern = new RegExp(
            `(${network}:\\s*{[^}]*bullaKycGateAddress:\\s*'[^']*',)`,
            's',
        );
        const afterAgreementPattern = new RegExp(
            `(${network}:\\s*{[^}]*agreementSignatureRepoAddress:\\s*'[^']*',)`,
            's',
        );

        if (afterGatePattern.test(content)) {
            content = content.replace(
                afterGatePattern,
                `$1\n        complianceDepositPermissionsAddress: '${permissionsAddress}',`,
            );
            console.log(`✅ Added complianceDepositPermissionsAddress for ${network}: ${permissionsAddress}`);
        } else if (afterAgreementPattern.test(content)) {
            content = content.replace(
                afterAgreementPattern,
                `$1\n        complianceDepositPermissionsAddress: '${permissionsAddress}',`,
            );
            console.log(`✅ Added complianceDepositPermissionsAddress for ${network}: ${permissionsAddress}`);
        } else {
            console.warn(`⚠️  Could not find ${network} network config to update`);
            return;
        }
    }

    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Extract ComplianceDepositPermissions address from broadcast and update config
 */
export function updateComplianceDepositPermissionsFromBroadcast(scriptName: string, network: string): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);
        const permissionsAddress = extractDeployedAddress(broadcast, 'ComplianceDepositPermissions');

        if (permissionsAddress) {
            updateComplianceDepositPermissionsAddress(network, permissionsAddress);
        } else {
            console.warn('⚠️  Could not find ComplianceDepositPermissions address in broadcast');
        }
    } catch (error) {
        console.error('❌ Error updating ComplianceDepositPermissions address:', (error as Error).message);
    }
}

/**
 * Update sanctions list address in network config (handles both 'undefined' and existing string values)
 */
export function updateSanctionsListAddress(network: string, sanctionsListAddress: string): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    // Match either: sanctionsListAddress: '0x...',  OR  sanctionsListAddress: undefined,
    const networkPattern = new RegExp(
        `(${network}:\\s*{[^}]*sanctionsListAddress:\\s*)(?:'[^']*'|undefined)`,
        's',
    );

    if (networkPattern.test(content)) {
        content = content.replace(networkPattern, `$1'${sanctionsListAddress}'`);
        console.log(`✅ Updated sanctionsListAddress for ${network}: ${sanctionsListAddress}`);
    } else {
        // Field doesn't exist — add it after BullaClaimInvoiceProviderAdapterAddress
        const afterAdapterPattern = new RegExp(
            `(${network}:\\s*{[^}]*BullaClaimInvoiceProviderAdapterAddress:\\s*'[^']*',)`,
            's',
        );

        if (afterAdapterPattern.test(content)) {
            content = content.replace(
                afterAdapterPattern,
                `$1\n        sanctionsListAddress: '${sanctionsListAddress}',`,
            );
            console.log(`✅ Added sanctionsListAddress for ${network}: ${sanctionsListAddress}`);
        } else {
            console.warn(`⚠️  Could not find ${network} network config to update`);
            return;
        }
    }

    writeFileSync(configPath, content, 'utf-8');
}

/**
 * Extract MockSanctionsList address from broadcast and update config
 */
export function updateMockSanctionsListFromBroadcast(scriptName: string, network: string): void {
    try {
        const broadcast = readLatestBroadcast(scriptName, network);
        const sanctionsListAddress = extractDeployedAddress(broadcast, 'MockSanctionsList');

        if (sanctionsListAddress) {
            updateSanctionsListAddress(network, sanctionsListAddress);
        } else {
            console.warn('⚠️  Could not find MockSanctionsList address in broadcast');
        }
    } catch (error) {
        console.error('❌ Error updating MockSanctionsList address:', (error as Error).message);
    }
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
