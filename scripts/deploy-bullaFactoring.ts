import { writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import addresses from '../addresses.json';
import ERC20 from '../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json';
import bullaFactoringABI from '../deployments/sepolia/BullaFactoring.json';

export const verifyContract = async (address: string, constructorArguments: any[], network: string) => {
    try {
        await hre.run('verify:verify', {
            address,
            constructorArguments,
            network,
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
        const { address: factoringPermissionsAddress } = await deploy('MockPermissions', {
            from: deployer,
            args: [],
        });
        await verifyContract(factoringPermissionsAddress, [], network);
        console.log(`MockFactoringPermissionsAddress deployed: ${factoringPermissionsAddress}`);
    } else {
        console.log(`Using provided factoringPermissionsAddress: ${factoringPermissionsAddress}`);
    }

    if (!depositPermissionsAddress) {
        const { address: depositPermissionsAddress } = await deploy('MockPermissions', {
            from: deployer,
            args: [],
        });
        await verifyContract(depositPermissionsAddress, [], network);
        console.log(`MockDepositPermissionsAddress deployed: ${depositPermissionsAddress}`);
    } else {
        console.log(`Using provided depositPermissionsAddress: ${depositPermissionsAddress}`);
    }

    // Deploy bulla factoring contract if not provided
    if (!bullaFactoringAddress) {
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

const sepoliaConfig = {
    bullaClaim: '0x3702D060cbB102b6AebF40B40880F77BeF3d7225', // Sepolia Address
    underlyingAsset: '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8', // Sepolia USDC
    underwriter: '0x201D274192Fa7b21ce802f0b87D75Ae493A8C93D', // Ben's address
    bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
    protocolFeeBps: 25,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Factoring Pool Sepolia v0.3',
    taxBps: 10,
    targetYieldBps: 730,
    poolTokenName: 'Bulla TCS Factoring Pool',
    poolTokenSymbol: 'BFT-TCS',
    network,
    BullaClaimInvoiceProviderAdapterAddress: '0x15ef2BD80BE2247C9007A35c761Ea9aDBe1063C5',
    factoringPermissionsAddress: '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e',
    depositPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
    bullaFactoringAddress: '0x9390258Fa2864b71537B037f65feD7abca3cB1B2',
    writeNewAddresses: true,
    setImpairReserve: true,
};

const polygonConfig = {
    bullaClaim: '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4', // Polygon Address
    underlyingAsset: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359', // Polygon USDC
    underwriter: '0x201D274192Fa7b21ce802f0b87D75Ae493A8C93D', // Ben's address
    bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
    protocolFeeBps: 25,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Factoring Pool - Polygon V0 Test',
    taxBps: 10,
    targetYieldBps: 730,
    poolTokenName: 'Bulla TCS Factoring Pool',
    poolTokenSymbol: 'BFT-TCS',
    network,
    BullaClaimInvoiceProviderAdapterAddress: '0xB5B31E95f0C732450Bc869A6467A9941C8565b10',
    factoringPermissionsAddress: '0x79B14C823A20DC5556A6922291020785B31274D5',
    depositPermissionsAddress: '0x052E0d83BCeF4e75917Fcc10aB89D3F0F505926b',
    writeNewAddresses: false,
    setImpairReserve: false,
};

const config = network === 'sepolia' ? sepoliaConfig : polygonConfig;

deployBullaFactoring(config)
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
