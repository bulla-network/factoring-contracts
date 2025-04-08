import { writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import ERC20 from '../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json';
import bullaFactoringABI from '../deployments/sepolia/BullaFactoring.json';
import { ethereumConfig, polygonConfig, sepoliaConfig } from './network-config';

export const verifyContract = async (address: string, constructorArguments: any[], network: string, contractName?: string) => {
    try {
        await hre.run('verify:verify', {
            address,
            constructorArguments,
            network,
            contractName,
        });
        console.log(`Contract verified: ${address}`);
    } catch (error: any) {
        if (error.message.includes('already verified')) {
            console.log(`Contract already verified: ${address}`);
        } else {
            throw error;
        }
    }
};

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
}: DeployBullaFactoringParams) => {
    const { deployments, getNamedAccounts, getChainId } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();
    const chainId = await getChainId();

    let addresses = {};
    try {
        addresses = require('../addresses.json');
    } catch (error) {
        console.log('No addresses.json file found. Creating a new one.');
    }

    // Deploy invoice provider contract if not provided
    if (!BullaClaimInvoiceProviderAdapterAddress) {
        const { address: BullaClaimInvoiceProviderAdapterAddress } = await deploy('BullaClaimInvoiceProviderAdapter', {
            from: deployer,
            args: [bullaClaim],
        });
        await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], network);
        console.log(`BullaClaimInvoiceProviderAdapter deployed: ${BullaClaimInvoiceProviderAdapterAddress}`);
    } else {
        console.log(`Using provided BullaClaimInvoiceProviderAdapterAddress: ${BullaClaimInvoiceProviderAdapterAddress}`);
    }

    // Deploy mock permissions contracts if not provided
    if (!factoringPermissionsAddress) {
        const { address: factoringPermissionsAddress } = await deploy('FactoringPermissions', {
            from: deployer,
            args: [],
        });
        await verifyContract(factoringPermissionsAddress, [], network, 'contracts/FactoringPermissions.sol:FactoringPermissions');
        console.log(`FactoringPermissionsAddress deployed: ${factoringPermissionsAddress}`);
    } else {
        console.log(`Using provided factoringPermissionsAddress: ${factoringPermissionsAddress}`);
    }

    if (!depositPermissionsAddress) {
        const { address: depositPermissionsAddress } = await deploy('DepositPermissions', {
            from: deployer,
            args: [],
        });
        await verifyContract(depositPermissionsAddress, [], network, 'contracts/DepositPermissions.sol:DepositPermissions');
        console.log(`DepositPermissionsAddress deployed: ${depositPermissionsAddress}`);
    } else {
        console.log(`Using provided depositPermissionsAddress: ${depositPermissionsAddress}`);
    }

    // Deploy bulla factoring contract if not provided
    if (!bullaFactoringAddress && factoringPermissionsAddress && depositPermissionsAddress) {
        const { address: bullaFactoringAddress } = await deploy('BullaFactoring', {
            from: deployer,
            args: [
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
        });

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
        console.log(`Bulla Factoring Contract deployed: ${bullaFactoringAddress}`);
    } else {
        console.log(`Using provided bullaFactoringAddress: ${bullaFactoringAddress}`);
    }

    // Set Impair Reserve and approve token
    if (setImpairReserve && bullaFactoringAddress) {
        const signer = await ethers.getSigner(deployer);
        const initialImpairReserve = 50000;
        const underlyingTokenContract = new ethers.Contract(underlyingAsset, ERC20.abi, signer);
        await underlyingTokenContract.approve(bullaFactoringAddress, initialImpairReserve);

        const bullaFactoringContract = new ethers.Contract(bullaFactoringAddress, bullaFactoringABI.abi, signer);
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
        deployer,
        chainId,
        currentTime: now.toISOString(),
        BullaClaimInvoiceProviderAdapterAddress,
        bullaFactoringAddress,
    };

    return deployInfo;
};

const network = process.env.NETWORK;

if (!network) {
    console.error('Please provide a network as an environment variable');
    process.exit(1);
}

// Use the imported network configurations - no duplication
const config = network === 'sepolia' ? sepoliaConfig : network === 'polygon' ? polygonConfig : ethereumConfig;

deployBullaFactoring({
    ...config,
    network,
})
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
