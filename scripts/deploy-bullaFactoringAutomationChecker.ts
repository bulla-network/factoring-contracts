import { writeFileSync } from 'fs';
import hre from 'hardhat';
import addresses from '../automation-addresses.json';
import { getNetworkFromEnv, verifyContract } from './deploy-utils';

export const deployBullaFactoringAutomationChecker = async function () {
    const { deployments, getNamedAccounts, getChainId } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    // Get the network from environment variable
    const network = getNetworkFromEnv();
    console.log(`Using network: ${network}`);

    console.log('Deploying Bulla Factoring Automation Checker...');

    // deploy factoring automation checker
    const { address: bullaFactoringAutomationCheckerAddress } = await deploy('BullaFactoringAutomationChecker', {
        from: deployer,
        args: [],
    });

    console.log(`Bulla Factoring Automation Checker deployed: ${bullaFactoringAutomationCheckerAddress}`);

    // Add verification step
    console.log('Verifying Bulla Factoring Automation Checker...');
    await verifyContract(
        bullaFactoringAutomationCheckerAddress,
        [], // No constructor arguments
        network,
        'contracts/BullaFactoringAutomationChecker.sol:BullaFactoringAutomationChecker',
    );
    console.log(`Bulla Factoring Automation Checker verified: ${bullaFactoringAutomationCheckerAddress}`);

    const chainId = await getChainId();

    const newAddresses: Record<number, string> = {
        ...addresses,
        [chainId]: bullaFactoringAutomationCheckerAddress,
    };

    writeFileSync('./automation-addresses.json', JSON.stringify(newAddresses, null, 2));

    const now = new Date();
    const deployInfo = {
        deployer,
        chainId: await getChainId(),
        currentTime: now.toISOString(),
        bullaFactoringAutomationCheckerAddress,
    };

    return deployInfo;
};

// Only run the function if this script is being executed directly
if (require.main === module) {
    deployBullaFactoringAutomationChecker()
        .then(() => process.exit(0))
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
