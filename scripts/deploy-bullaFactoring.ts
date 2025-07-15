import { writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import ERC20 from '../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json';
import bullaFactoringABI from '../deployments/sepolia/BullaFactoring.json';
import { getNetworkFromEnv, verifyContract } from './deploy-utils';
import { ethereumConfig, polygonConfig, sepoliaConfig, sepoliaFudorraConfig } from './network-config';

export type DeployBullaFactoringParams = {
    bullaClaim: string;
    underlyingAsset: string;
    underwriter: string;
    bullaDao: string;
    protocolFeeBps: number;
    adminFeeBps: number;
    poolName: string;
    targetYieldBps: number;
    poolTokenName: string;
    poolTokenSymbol: string;
    network: string;
    BullaClaimInvoiceProviderAdapterAddress?: string;
    factoringPermissionsAddress?: string;
    depositPermissionsAddress?: string;
    redeemPermissionsAddress?: string;
    bullaFactoringAddress?: string;
    bullaFrendLendAddress?: string;
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
    targetYieldBps,
    poolTokenName,
    poolTokenSymbol,
    network,
    BullaClaimInvoiceProviderAdapterAddress,
    factoringPermissionsAddress,
    depositPermissionsAddress,
    redeemPermissionsAddress,
    bullaFrendLendAddress,
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
        console.log('Deploying BullaClaimInvoiceProviderAdapter...');
        const { address: BullaClaimInvoiceProviderAdapterAddress } = await deploy('BullaClaimInvoiceProviderAdapter', {
            from: deployer,
            args: [bullaClaim],
        });
        console.log(`BullaClaimInvoiceProviderAdapter deployed: ${BullaClaimInvoiceProviderAdapterAddress}`);
        console.log('Verifying BullaClaimInvoiceProviderAdapter...');
        await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], network);
        console.log(`BullaClaimInvoiceProviderAdapter verified: ${BullaClaimInvoiceProviderAdapterAddress}`);
    } else {
        console.log(`Using provided BullaClaimInvoiceProviderAdapterAddress: ${BullaClaimInvoiceProviderAdapterAddress}`);
    }

    // Deploy mock permissions contracts if not provided
    if (!factoringPermissionsAddress) {
        console.log('Deploying FactoringPermissions...');
        const { address: factoringPermissionsAddress } = await deploy('FactoringPermissions', {
            from: deployer,
            args: [],
        });
        console.log(`FactoringPermissionsAddress deployed: ${factoringPermissionsAddress}`);
        console.log('Verifying FactoringPermissions...');
        await verifyContract(factoringPermissionsAddress, [], network, 'contracts/FactoringPermissions.sol:FactoringPermissions');
        console.log(`FactoringPermissionsAddress verified: ${factoringPermissionsAddress}`);
    } else {
        console.log(`Using provided factoringPermissionsAddress: ${factoringPermissionsAddress}`);
    }

    if (!depositPermissionsAddress) {
        console.log('Deploying DepositPermissions...');
        const { address: depositPermissionsAddress } = await deploy('DepositPermissions', {
            from: deployer,
            args: [],
        });
        console.log(`DepositPermissionsAddress deployed: ${depositPermissionsAddress}`);
        console.log('Verifying DepositPermissions...');
        await verifyContract(depositPermissionsAddress, [], network, 'contracts/DepositPermissions.sol:DepositPermissions');
        console.log(`DepositPermissionsAddress verified: ${depositPermissionsAddress}`);
    } else {
        console.log(`Using provided depositPermissionsAddress: ${depositPermissionsAddress}`);
    }

    // Deploy bulla factoring contract if not provided
    if (!bullaFactoringAddress && factoringPermissionsAddress && depositPermissionsAddress) {
        console.log('Deploying Bulla Factoring Contract...');
        const { address: bullaFactoringAddress } = await deploy('BullaFactoringV2', {
            from: deployer,
            args: [
                underlyingAsset,
                BullaClaimInvoiceProviderAdapterAddress,
                bullaFrendLendAddress,
                underwriter,
                depositPermissionsAddress,
                redeemPermissionsAddress,
                factoringPermissionsAddress,
                bullaDao,
                protocolFeeBps,
                adminFeeBps,
                poolName,
                targetYieldBps,
                poolTokenName,
                poolTokenSymbol,
            ],
        });

        console.log(`Bulla Factoring Contract deployed: ${bullaFactoringAddress}`);
        console.log('Verifying Bulla Factoring Contract...');
        await verifyContract(
            bullaFactoringAddress,
            [
                underlyingAsset,
                BullaClaimInvoiceProviderAdapterAddress,
                bullaFrendLendAddress,
                underwriter,
                depositPermissionsAddress,
                redeemPermissionsAddress,
                factoringPermissionsAddress,
                bullaDao,
                protocolFeeBps,
                adminFeeBps,
                poolName,
                targetYieldBps,
                poolTokenName,
                poolTokenSymbol,
            ],
            network,
        );
        console.log(`Bulla Factoring Contract verified: ${bullaFactoringAddress}`);
    } else {
        console.log(`Using provided bullaFactoringAddress: ${bullaFactoringAddress}`);
    }

    // Set Impair Reserve and approve token
    if (setImpairReserve && bullaFactoringAddress) {
        console.log('Setting Impair Reserve and approving token...');
        const signer = await ethers.getSigner(deployer);
        const initialImpairReserve = 50000;
        const underlyingTokenContract = new ethers.Contract(underlyingAsset, ERC20.abi, signer);
        console.log('Approving token...');
        await underlyingTokenContract.approve(bullaFactoringAddress, initialImpairReserve);
        console.log('Token approved');

        const bullaFactoringContract = new ethers.Contract(bullaFactoringAddress, bullaFactoringABI.abi, signer);
        console.log('Setting Impair Reserve...');
        await bullaFactoringContract.setImpairReserve(initialImpairReserve);
        console.log('Impair Reserve set');

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
                    bullaFrendLend: bullaFrendLendAddress,
                    depositPermissions: depositPermissionsAddress,
                    redeemPermissions: redeemPermissionsAddress,
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

// Only run the function if this script is being executed directly
if (require.main === module) {
    const network = getNetworkFromEnv();

    // Use the imported network configurations - no duplication
    const config =
        network === 'sepolia'
            ? sepoliaConfig
            : network === 'sepoliaFudorra'
            ? sepoliaFudorraConfig
            : network === 'polygon'
            ? polygonConfig
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
