import hre, { ethers } from 'hardhat';
import { getNetworkFromEnv, verifyContract } from './deploy-utils';
import { baseConfig, ethereumConfig, polygonConfig, sepoliaConfig, sepoliaFundoraConfig, taramRedbellyConfig } from './network-config';

export type VerifyBullaFactoringParams = {
    bullaClaim: string;
    underlyingAsset: string;
    underwriter: string;
    bullaDao: string;
    protocolFeeBps: number;
    adminFeeBps: number;
    poolName: string;
    taxBps: number;
    targetYieldBps: number;
    poolTokenName: string;
    poolTokenSymbol: string;
    network: string;
    BullaClaimInvoiceProviderAdapterAddress: string;
    factoringPermissionsAddress: string;
    depositPermissionsAddress: string;
    bullaFactoringAddress: string;
    usePermissionsWithReconcile?: boolean;
};

/**
 * Verifies all deployed BullaFactoring contracts on the block explorer
 * @param params Verification parameters including contract addresses and constructor args
 */
export const verifyBullaFactoring = async ({
    bullaClaim,
    underlyingAsset,
    underwriter,
    bullaDao,
    protocolFeeBps,
    adminFeeBps,
    poolName,
    taxBps,
    targetYieldBps,
    poolTokenName,
    poolTokenSymbol,
    network,
    BullaClaimInvoiceProviderAdapterAddress,
    factoringPermissionsAddress,
    depositPermissionsAddress,
    bullaFactoringAddress,
    usePermissionsWithReconcile = false,
}: VerifyBullaFactoringParams) => {
    console.log(`\n=== Verifying BullaFactoring contracts on ${network} ===\n`);

    const verificationResults = {
        adapter: false,
        factoringPermissions: false,
        depositPermissions: false,
        bullaFactoring: false,
    };

    // Verify BullaClaimInvoiceProviderAdapter
    if (BullaClaimInvoiceProviderAdapterAddress) {
        console.log('Verifying BullaClaimInvoiceProviderAdapter...');
        try {
            await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], network);
            console.log(`✅ BullaClaimInvoiceProviderAdapter verified: ${BullaClaimInvoiceProviderAdapterAddress}`);
            verificationResults.adapter = true;
        } catch (error: any) {
            console.log(`❌ Verification failed for BullaClaimInvoiceProviderAdapter: ${error.message}`);
        }
    } else {
        console.log('⚠️  BullaClaimInvoiceProviderAdapterAddress not provided, skipping verification');
    }

    // Verify Factoring Permissions Contract
    if (factoringPermissionsAddress) {
        console.log('\nVerifying Factoring Permissions Contract...');
        try {
            if (usePermissionsWithReconcile) {
                await verifyContract(
                    factoringPermissionsAddress,
                    [],
                    network,
                    'contracts/PermissionsWithReconcile.sol:PermissionsWithReconcile',
                );
                console.log(`✅ PermissionsWithReconcile (factoring) verified: ${factoringPermissionsAddress}`);
            } else {
                await verifyContract(factoringPermissionsAddress, [], network, 'contracts/FactoringPermissions.sol:FactoringPermissions');
                console.log(`✅ FactoringPermissions verified: ${factoringPermissionsAddress}`);
            }
            verificationResults.factoringPermissions = true;
        } catch (error: any) {
            console.log(`❌ Verification failed for Factoring Permissions: ${error.message}`);
        }
    } else {
        console.log('⚠️  factoringPermissionsAddress not provided, skipping verification');
    }

    // Verify Deposit Permissions Contract
    if (depositPermissionsAddress) {
        console.log('\nVerifying Deposit Permissions Contract...');
        try {
            if (usePermissionsWithReconcile) {
                await verifyContract(
                    depositPermissionsAddress,
                    [],
                    network,
                    'contracts/PermissionsWithReconcile.sol:PermissionsWithReconcile',
                );
                console.log(`✅ PermissionsWithReconcile (deposit) verified: ${depositPermissionsAddress}`);
            } else {
                await verifyContract(depositPermissionsAddress, [], network, 'contracts/DepositPermissions.sol:DepositPermissions');
                console.log(`✅ DepositPermissions verified: ${depositPermissionsAddress}`);
            }
            verificationResults.depositPermissions = true;
        } catch (error: any) {
            console.log(`❌ Verification failed for Deposit Permissions: ${error.message}`);
        }
    } else {
        console.log('⚠️  depositPermissionsAddress not provided, skipping verification');
    }

    // Verify BullaFactoring Contract
    if (bullaFactoringAddress) {
        console.log('\nVerifying BullaFactoring Contract...');
        try {
            await verifyContract(
                bullaFactoringAddress,
                [
                    underlyingAsset,
                    BullaClaimInvoiceProviderAdapterAddress,
                    underwriter,
                    depositPermissionsAddress,
                    factoringPermissionsAddress,
                    bullaDao,
                    protocolFeeBps,
                    adminFeeBps,
                    poolName,
                    taxBps,
                    targetYieldBps,
                    poolTokenName,
                    poolTokenSymbol,
                ],
                network,
            );
            console.log(`✅ BullaFactoring verified: ${bullaFactoringAddress}`);
            verificationResults.bullaFactoring = true;
        } catch (error: any) {
            console.log(`❌ Verification failed for BullaFactoring: ${error.message}`);
        }
    } else {
        console.log('⚠️  bullaFactoringAddress not provided, skipping verification');
    }

    // Summary
    console.log('\n=== Verification Summary ===');
    console.log(`BullaClaimInvoiceProviderAdapter: ${verificationResults.adapter ? '✅' : '❌'}`);
    console.log(`Factoring Permissions: ${verificationResults.factoringPermissions ? '✅' : '❌'}`);
    console.log(`Deposit Permissions: ${verificationResults.depositPermissions ? '✅' : '❌'}`);
    console.log(`BullaFactoring: ${verificationResults.bullaFactoring ? '✅' : '❌'}`);

    const successCount = Object.values(verificationResults).filter(Boolean).length;
    const totalCount = Object.values(verificationResults).length;
    console.log(`\nTotal: ${successCount}/${totalCount} contracts verified successfully`);

    return verificationResults;
};

/**
 * Verifies contracts using addresses from addresses.json
 * @param bullaFactoringAddress The main BullaFactoring contract address
 * @param network The network to verify on
 */
export const verifyFromAddresses = async (bullaFactoringAddress: string, network: string) => {
    console.log(`Loading addresses from addresses.json for ${bullaFactoringAddress}...`);

    const { getChainId } = hre;
    const chainId = await getChainId();

    let addresses: any = {};
    try {
        addresses = require('../addresses.json');
    } catch (error) {
        throw new Error('addresses.json file not found. Please deploy contracts first.');
    }

    const chainAddresses = addresses[chainId];
    if (!chainAddresses) {
        throw new Error(`No addresses found for chain ID ${chainId} in addresses.json`);
    }

    const contractInfo = chainAddresses[bullaFactoringAddress];
    if (!contractInfo) {
        throw new Error(`Contract ${bullaFactoringAddress} not found in addresses.json for chain ${chainId}`);
    }

    // Get network configuration
    const config =
        network === 'sepolia'
            ? sepoliaConfig
            : network === 'sepoliaFundora'
            ? sepoliaFundoraConfig
            : network === 'polygon'
            ? polygonConfig
            : network === 'base'
            ? baseConfig
            : network === 'redbelly'
            ? taramRedbellyConfig
            : ethereumConfig;

    return verifyBullaFactoring({
        ...config,
        network,
        BullaClaimInvoiceProviderAdapterAddress: contractInfo.bullaClaimInvoiceProviderAdapter,
        factoringPermissionsAddress: contractInfo.factoringPermissions,
        depositPermissionsAddress: contractInfo.depositPermissions,
        bullaFactoringAddress,
    });
};

// CLI Interface
if (require.main === module) {
    const args = process.argv.slice(2);
    const network = getNetworkFromEnv();

    if (args.length === 0) {
        console.log('Usage:');
        console.log('  npm run verify-factoring <bullaFactoringAddress>');
        console.log('  OR');
        console.log('  NETWORK=sepolia npx ts-node scripts/verify-bullaFactoring.ts <bullaFactoringAddress>');
        console.log('');
        console.log('This will verify all related contracts using addresses from addresses.json');
        process.exit(1);
    }

    const bullaFactoringAddress = args[0];

    if (!ethers.utils.isAddress(bullaFactoringAddress)) {
        console.error('❌ Invalid contract address provided');
        process.exit(1);
    }

    console.log(`Network: ${network}`);
    console.log(`BullaFactoring Address: ${bullaFactoringAddress}`);

    verifyFromAddresses(bullaFactoringAddress, network)
        .then(results => {
            const allVerified = Object.values(results).every(Boolean);
            process.exit(allVerified ? 0 : 1);
        })
        .catch(error => {
            console.error('❌ Verification failed:', error.message);
            process.exit(1);
        });
}
