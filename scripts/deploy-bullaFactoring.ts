import { writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import ERC20 from '../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json';
import bullaFactoringABI from '../deployments/sepolia/BullaFactoring.json';
import { getNetworkFromEnv, verifyContract } from './deploy-utils';
import { baseConfig, ethereumConfig, polygonConfig, sepoliaConfig, sepoliaFundoraConfig, taramRedbellyConfig } from './network-config';
import { ensurePrivateKey } from './private-key-utils';

export type DeployBullaFactoringParams = {
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
    BullaClaimInvoiceProviderAdapterAddress?: string;
    factoringPermissionsAddress?: string;
    depositPermissionsAddress?: string;
    bullaFactoringAddress?: string;
    writeNewAddresses?: boolean;
    setImpairReserve?: boolean;
    usePermissionsWithReconcile?: boolean;
};

export const deployBullaFactoring = async ({
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
    writeNewAddresses = true,
    setImpairReserve = true,
    usePermissionsWithReconcile = false,
}: DeployBullaFactoringParams) => {
    // Ensure we have a valid private key for deployment
    const privateKey = await ensurePrivateKey();

    const { getChainId } = hre;
    const chainId = await getChainId();

    // Create wallet with the prompted private key
    const wallet = new ethers.Wallet(privateKey, ethers.provider);
    console.log(`Deploying from address: ${wallet.address}`);
    let addresses = {};
    try {
        addresses = require('../addresses.json');
    } catch (error) {
        console.log('No addresses.json file found. Creating a new one.');
    }

    // Deploy invoice provider contract if not provided
    if (!BullaClaimInvoiceProviderAdapterAddress) {
        console.log('Deploying BullaClaimInvoiceProviderAdapter...');

        // Deploy directly using ethers instead of hardhat-deploy to avoid signer issues
        const BullaClaimInvoiceProviderAdapterFactory = await ethers.getContractFactory('BullaClaimInvoiceProviderAdapter', wallet);
        const bullaClaimInvoiceProviderAdapter = await BullaClaimInvoiceProviderAdapterFactory.deploy(bullaClaim);
        await bullaClaimInvoiceProviderAdapter.deployed();
        BullaClaimInvoiceProviderAdapterAddress = bullaClaimInvoiceProviderAdapter.address;
        console.log(`BullaClaimInvoiceProviderAdapter deployed: ${BullaClaimInvoiceProviderAdapterAddress}`);
        console.log('Verifying BullaClaimInvoiceProviderAdapter...');
        try {
            await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], network);
            console.log(`BullaClaimInvoiceProviderAdapter verified: ${BullaClaimInvoiceProviderAdapterAddress}`);
        } catch (error) {
            console.log(`Verification failed for BullaClaimInvoiceProviderAdapter: ${error.message}`);
            console.log('Continuing with deployment...');
        }
    } else {
        console.log(`Using provided BullaClaimInvoiceProviderAdapterAddress: ${BullaClaimInvoiceProviderAdapterAddress}`);
    }

    // Deploy permissions contracts if not provided
    if (!factoringPermissionsAddress) {
        if (usePermissionsWithReconcile) {
            console.log('Deploying PermissionsWithReconcile for factoring...');
            const PermissionsWithReconcileFactory = await ethers.getContractFactory('PermissionsWithReconcile', wallet);
            const factoringPermissions = await PermissionsWithReconcileFactory.deploy();
            await factoringPermissions.deployed();
            factoringPermissionsAddress = factoringPermissions.address;
            console.log(`PermissionsWithReconcile deployed: ${factoringPermissionsAddress}`);
            console.log('Verifying PermissionsWithReconcile...');
            try {
                await verifyContract(
                    factoringPermissionsAddress,
                    [],
                    network,
                    'contracts/PermissionsWithReconcile.sol:PermissionsWithReconcile',
                );
                console.log(`PermissionsWithReconcile verified: ${factoringPermissionsAddress}`);
            } catch (error) {
                console.log(`Verification failed for PermissionsWithReconcile: ${error.message}`);
                console.log('Continuing with deployment...');
            }
        } else {
            console.log('Deploying FactoringPermissions...');
            const FactoringPermissionsFactory = await ethers.getContractFactory('FactoringPermissions', wallet);
            const factoringPermissions = await FactoringPermissionsFactory.deploy();
            await factoringPermissions.deployed();
            factoringPermissionsAddress = factoringPermissions.address;
            console.log(`FactoringPermissions deployed: ${factoringPermissionsAddress}`);
            console.log('Verifying FactoringPermissions...');
            try {
                await verifyContract(factoringPermissionsAddress, [], network, 'contracts/FactoringPermissions.sol:FactoringPermissions');
                console.log(`FactoringPermissions verified: ${factoringPermissionsAddress}`);
            } catch (error) {
                console.log(`Verification failed for FactoringPermissions: ${error.message}`);
                console.log('Continuing with deployment...');
            }
        }
    } else {
        console.log(`Using provided factoringPermissionsAddress: ${factoringPermissionsAddress}`);
    }

    if (!depositPermissionsAddress) {
        if (usePermissionsWithReconcile) {
            console.log('Deploying PermissionsWithReconcile for deposits...');
            const PermissionsWithReconcileFactory = await ethers.getContractFactory('PermissionsWithReconcile', wallet);
            const depositPermissions = await PermissionsWithReconcileFactory.deploy();
            await depositPermissions.deployed();
            depositPermissionsAddress = depositPermissions.address;
            console.log(`PermissionsWithReconcile deployed: ${depositPermissionsAddress}`);
            console.log('Verifying PermissionsWithReconcile...');
            try {
                await verifyContract(
                    depositPermissionsAddress,
                    [],
                    network,
                    'contracts/PermissionsWithReconcile.sol:PermissionsWithReconcile',
                );
                console.log(`PermissionsWithReconcile verified: ${depositPermissionsAddress}`);
            } catch (error) {
                console.log(`Verification failed for PermissionsWithReconcile: ${error.message}`);
                console.log('Continuing with deployment...');
            }
        } else {
            console.log('Deploying DepositPermissions...');
            const DepositPermissionsFactory = await ethers.getContractFactory('DepositPermissions', wallet);
            const depositPermissions = await DepositPermissionsFactory.deploy();
            await depositPermissions.deployed();
            depositPermissionsAddress = depositPermissions.address;
            console.log(`DepositPermissions deployed: ${depositPermissionsAddress}`);
            console.log('Verifying DepositPermissions...');
            try {
                await verifyContract(depositPermissionsAddress, [], network, 'contracts/DepositPermissions.sol:DepositPermissions');
                console.log(`DepositPermissions verified: ${depositPermissionsAddress}`);
            } catch (error) {
                console.log(`Verification failed for DepositPermissions: ${error.message}`);
                console.log('Continuing with deployment...');
            }
        }
    } else {
        console.log(`Using provided depositPermissionsAddress: ${depositPermissionsAddress}`);
    }

    // Deploy bulla factoring contract if not provided
    if (!bullaFactoringAddress && factoringPermissionsAddress && depositPermissionsAddress) {
        console.log('Deploying Bulla Factoring Contract...');
        const BullaFactoringFactory = await ethers.getContractFactory('BullaFactoring', wallet);
        const bullaFactoring = await BullaFactoringFactory.deploy(
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
            {
                gasLimit: 8000000, // 8M gas limit for large contract deployment
            },
        );
        await bullaFactoring.deployed();
        bullaFactoringAddress = bullaFactoring.address;

        console.log(`Bulla Factoring Contract deployed: ${bullaFactoringAddress}`);

        // Set BullaFactoring pool address in permission contracts if using PermissionsWithReconcile
        if (usePermissionsWithReconcile) {
            const factoringPermissionsContract = await ethers.getContractAt(
                'PermissionsWithReconcile',
                factoringPermissionsAddress,
                wallet,
            );
            const depositPermissionsContract = await ethers.getContractAt('PermissionsWithReconcile', depositPermissionsAddress, wallet);
            await factoringPermissionsContract.setBullaFactoringPool(bullaFactoringAddress);
            await depositPermissionsContract.setBullaFactoringPool(bullaFactoringAddress);
            console.log('BullaFactoring pool address set in PermissionsWithReconcile contracts');
        }

        console.log('Verifying Bulla Factoring Contract...');
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
            console.log(`Bulla Factoring Contract verified: ${bullaFactoringAddress}`);
        } catch (error) {
            console.log(`Verification failed for BullaFactoring: ${error.message}`);
            console.log('Continuing with deployment...');
        }
    } else {
        console.log(`Using provided bullaFactoringAddress: ${bullaFactoringAddress}`);
    }

    // Set Impair Reserve and approve token
    if (setImpairReserve && bullaFactoringAddress) {
        const initialImpairReserve = 50000;
        const underlyingTokenContract = new ethers.Contract(underlyingAsset, ERC20.abi, wallet);
        await underlyingTokenContract.approve(bullaFactoringAddress, initialImpairReserve);

        const bullaFactoringContract = new ethers.Contract(bullaFactoringAddress, bullaFactoringABI.abi, wallet);
        await bullaFactoringContract.setImpairReserve(initialImpairReserve);

        const impairReserve = await bullaFactoringContract.impairReserve();
        console.log('Bulla Factoring Impair Reserve Set to: \n', impairReserve);
    } else {
        console.log('Skipping Impair Reserve setting');
    }

    if (writeNewAddresses && bullaFactoringAddress) {
        const newAddresses = {
            ...addresses,
            [chainId]: {
                ...((addresses[chainId as keyof typeof addresses] as object) ?? {}),
                [bullaFactoringAddress]: {
                    name: poolName,
                    bullaClaimInvoiceProviderAdapter: BullaClaimInvoiceProviderAdapterAddress,
                    depositPermissions: depositPermissionsAddress,
                    factoringPermissions: factoringPermissionsAddress,
                },
            },
        };
        writeFileSync('./addresses.json', JSON.stringify(newAddresses, null, 2));
    }

    const now = new Date();
    const deployInfo = {
        deployer: wallet.address,
        chainId,
        currentTime: now.toISOString(),
        BullaClaimInvoiceProviderAdapterAddress,
        bullaFactoringAddress,
    };

    return deployInfo;
};

// Only run the function if this script is being executed directly
if (require.main === module) {
    const network = getNetworkFromEnv();

    // Use the imported network configurations - no duplication
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

    deployBullaFactoring({
        ...config,
        network,
    })
        .then(() => process.exit(0))
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
