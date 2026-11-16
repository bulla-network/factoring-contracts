import { utils } from 'ethers';
import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { CURRENT_POOL_VERSION, getChainId, PoolName, poolContractName, PoolVersion, toContractVersion } from '../network-config';
import { findPendingPool, loadPendingPools, recordDeployedPool } from './pools';

/**
 * Read the latest broadcast file for a script
 */
function readLatestBroadcast(scriptName: string, network: string): any {
    const broadcastPath = join('broadcast', scriptName, String(getChainId(network)), 'run-latest.json');
    try {
        const content = readFileSync(broadcastPath, 'utf-8');
        return JSON.parse(content);
    } catch (error) {
        console.error(`Failed to read broadcast file: ${broadcastPath}`);
        throw error;
    }
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
 * Record the adapter for one chain and pool contract version in versionConfigs (POOLDEPLOY R5)
 */
export function updateAdapterAddress(network: string, adapterAddress: string, version: PoolVersion = CURRENT_POOL_VERSION): void {
    const configPath = join('scripts', 'network-config.ts');
    let content = readFileSync(configPath, 'utf-8');

    const blockMatch = content.match(/export const versionConfigs[^=]*=\s*\{[\s\S]*?\n\};/);
    if (!blockMatch) {
        console.warn('⚠️  Could not find versionConfigs in network-config.ts');
        return;
    }
    let block = blockMatch[0];
    const entry = `'${version}': { invoiceProviderAdapterAddress: '${adapterAddress}' },`;

    const networkBlock = block.match(new RegExp(`\\n    ${network}: \\{[\\s\\S]*?\\n    \\},`));
    const versionEntry = new RegExp(`'${version.replace('.', '\\.')}': \\{[^}]*\\},`);

    if (networkBlock && versionEntry.test(networkBlock[0])) {
        block = block.replace(networkBlock[0], networkBlock[0].replace(versionEntry, entry));
        console.log(`✅ Updated ${version} adapter for ${network}: ${adapterAddress}`);
    } else if (networkBlock) {
        block = block.replace(networkBlock[0], networkBlock[0].replace(/\n    \},$/, `\n        ${entry}\n    },`));
        console.log(`✅ Added ${version} adapter for ${network}: ${adapterAddress}`);
    } else {
        block = block.replace(/\n\};$/, `\n    ${network}: {\n        ${entry}\n    },\n};`);
        console.log(`✅ Added ${network} with ${version} adapter: ${adapterAddress}`);
    }

    content = content.replace(blockMatch[0], block);
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
        // If it doesn't exist, add it after bullaInvoiceAddress
        const afterAdapterPattern = new RegExp(
            `(${network}:\\s*{[^}]*bullaInvoiceAddress:\\s*'[^']*',)`,
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
        // If it doesn't exist, add it after sumsubKycIssuerAddress (or bullaInvoiceAddress as fallback)
        const afterSumsubPattern = new RegExp(
            `(${network}:\\s*{[^}]*sumsubKycIssuerAddress:\\s*'[^']*',)`,
            's',
        );
        const afterAdapterPattern = new RegExp(
            `(${network}:\\s*{[^}]*bullaInvoiceAddress:\\s*'[^']*',)`,
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
        // Field doesn't exist — add it after bullaInvoiceAddress
        const afterAdapterPattern = new RegExp(
            `(${network}:\\s*{[^}]*bullaInvoiceAddress:\\s*'[^']*',)`,
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
 * The block of the transaction that created `address`, from the broadcast's receipts
 */
function extractDeployBlock(broadcast: any, address: string): number | undefined {
    const tx = (broadcast.transactions || []).find(
        (t: any) => t.transactionType === 'CREATE' && t.contractAddress?.toLowerCase() === address.toLowerCase(),
    );
    const receipt = (broadcast.receipts || []).find((r: any) => r.transactionHash === tx?.hash);
    if (!receipt?.blockNumber) return undefined;
    return typeof receipt.blockNumber === 'number' ? receipt.blockNumber : parseInt(receipt.blockNumber, 16);
}

/**
 * Records the pool a DeployBullaFactoring broadcast created in bulla_registry_export/pools.json (DEV-2937), from its
 * scripts/pending-pools.json entry, and the adapter it deployed, if any, in network-config.ts. Throws if the
 * broadcast has no pool or the pool can't be recorded, since a deployed pool missing from pools.json is invisible
 * to every other repo.
 */
export function recordFactoringFromBroadcast(scriptName: string, network: string, pool: PoolName): void {
    const broadcast = readLatestBroadcast(scriptName, network);

    const pending = findPendingPool(loadPendingPools(), network, pool);
    if (!pending) throw new Error(`${network}/${pool} is not in scripts/pending-pools.json, so there is nothing to record`);

    // The deploy builds this repo's pool contract, so the broadcast has the current version's
    const contractName = poolContractName(CURRENT_POOL_VERSION);
    const poolAddress = extractDeployedAddress(broadcast, contractName);
    if (!poolAddress) throw new Error(`No ${contractName} created in the latest broadcast`);
    const deployBlock = extractDeployBlock(broadcast, poolAddress);
    if (deployBlock === undefined) throw new Error(`No receipt for the pool ${poolAddress} in the latest broadcast`);

    // Same choices as script/DeployBullaFactoring.s.sol: reuse what the pending entry names, else what the broadcast created
    const factoring = pending.permissions?.factoring ?? extractDeployedAddress(broadcast, 'FactoringPermissions');
    const deposit = pending.permissions?.deposit ?? extractDeployedAddress(broadcast, 'DepositPermissions');
    if (!factoring || !deposit) throw new Error('Could not find the pool\'s permissions contracts in the pending entry or the broadcast');
    const redeem = pending.permissions?.redeem ?? deposit;
    const checksum = utils.getAddress;

    const recorded = recordDeployedPool(pending, {
        address: checksum(poolAddress),
        version: toContractVersion(CURRENT_POOL_VERSION),
        deployBlock,
        permissions: { factoring: checksum(factoring), deposit: checksum(deposit), redeem: checksum(redeem) },
        // DeployConfig.sol's default when INSURANCE_FEE_BPS is unset
        insuranceBps: pending.fees.insuranceBps ?? 100,
    });
    console.log(`✅ Recorded ${network}/${pool} in bulla_registry_export/pools.json: ${recorded.address} (block ${deployBlock})`);

    // The deploy script deploys an adapter when this version has none on the chain; record it so later pools reuse it
    const adapterAddress = extractDeployedAddress(broadcast, 'BullaClaimV2InvoiceProviderAdapterV2');
    if (adapterAddress) updateAdapterAddress(network, adapterAddress);
}
