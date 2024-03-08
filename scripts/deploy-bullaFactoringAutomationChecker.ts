import { writeFileSync } from 'fs';
import hre from 'hardhat';
import addresses from '../automation-addresses.json';

export const deployBullaFactoringAutomationChecker = async function () {
    const { deployments, getNamedAccounts, getChainId } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    // deploy factoring automation checker
    const { address: bullaFactoringAutomationCheckerAddress } = await deploy('BullaFactoringAutomationChecker', {
        from: deployer,
        args: [],
    });

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
    console.log('Bulla Factoring Automation Checker Deployment Address: \n', bullaFactoringAutomationCheckerAddress);

    return deployInfo;
};

// uncomment this line to run the script individually
deployBullaFactoringAutomationChecker()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
