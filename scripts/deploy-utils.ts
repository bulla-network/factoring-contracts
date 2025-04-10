/**
 * Shared utilities for deployment scripts
 */
import hre from 'hardhat';

/**
 * Verifies a contract on Etherscan or other block explorers
 * @param address Contract address to verify
 * @param constructorArguments Constructor arguments used during deployment
 * @param network Network name (mainnet, polygon, sepolia)
 * @param contractPath Optional path to contract in format "contracts/Contract.sol:ContractName"
 */
export const verifyContract = async (address: string, constructorArguments: any[], network: string, contractPath?: string) => {
    try {
        await hre.run('verify:verify', {
            address,
            constructorArguments,
            network,
            contract: contractPath,
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

/**
 * Gets the network from environment variable
 * @returns The network name or throws an error if not provided
 */
export const getNetworkFromEnv = (): string => {
    const network = process.env.NETWORK;
    if (!network) {
        throw new Error('Please provide a network as an environment variable');
    }
    return network;
};
