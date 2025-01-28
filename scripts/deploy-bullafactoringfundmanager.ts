import { writeFileSync } from 'fs';
import hre from 'hardhat';

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
    factoringPool: string;
    minInvestment: number;
    capitalCaller: string;
    network: string;
};

export const deployBullaFactoring = async ({ factoringPool, minInvestment, capitalCaller, network }: DeployBullaFactoringParams) => {
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

    const { address: factoringFundManagerAddress } = await deploy('BullaFactoringFundManager', {
        from: deployer,
        args: [factoringPool, minInvestment, capitalCaller],
    });

    await verifyContract(factoringFundManagerAddress, [factoringPool, minInvestment, capitalCaller], network);

    if (factoringFundManagerAddress) {
        const newAddresses = {
            ...addresses,
            [chainId]: {
                ...((addresses[chainId as keyof typeof addresses] as object) ?? {}),
                BullaFactoringFundManager: factoringFundManagerAddress,
            },
        };
        writeFileSync('./addresses.json', JSON.stringify(newAddresses, null, 2));
    }

    const now = new Date();
    const deployInfo = {
        deployer,
        chainId,
        currentTime: now.toISOString(),
        BullaFactoringFundManager: factoringFundManagerAddress,
    };

    return deployInfo;
};

const network = process.env.NETWORK;

if (!network) {
    console.error('Please provide a network as an environment variable');
    process.exit(1);
}

const sepoliaConfig = {
    factoringPool: '0xDF0fCe31285dcAB9124bF763AB9E5466723BeF35',
    capitalCaller: '0x89e03E7980C92fd81Ed3A9b72F5c73fDf57E5e6D', // Mike's address
    minInvestment: 1_000000, // 1 USDC
    network,
};

const polygonConfig = {
    factoringPool: '0xA7033191Eb07DC6205015075B204Ba0544bc460d',
    capitalCaller: '0x89e03E7980C92fd81Ed3A9b72F5c73fDf57E5e6D', // Mike's address
    minInvestment: 1_000_000000, // 1000 USDC
    network,
};

const config = network === 'sepolia' ? sepoliaConfig : polygonConfig;

deployBullaFactoring(config)
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
