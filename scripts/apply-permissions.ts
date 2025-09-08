import hre, { ethers } from 'hardhat';
import depositPermissionsABI from '../artifacts/contracts/DepositPermissions.sol/DepositPermissions.json';
import factoringPermissionsABI from '../artifacts/contracts/FactoringPermissions.sol/FactoringPermissions.json';
import { getNetworkFromEnv } from './deploy-utils';
import { getNetworkConfig } from './network-config';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    const { getNamedAccounts, getChainId } = hre;
    const { deployer } = await getNamedAccounts();
    const lineReader = getLineReader();
    const signer = await ethers.getSigner(deployer);

    // Get the network from environment variable
    const network = getNetworkFromEnv();
    console.log(`Using network: ${network}`);

    // Get the configuration for the specified network
    const config = getNetworkConfig(network);

    console.log(`Using addresses for ${network}:`);
    console.log(`- Bulla Factoring: ${config.bullaFactoringAddress}`);
    console.log(`- Deposit Permissions: ${config.depositPermissionsAddress}`);
    console.log(`- Factoring Permissions: ${config.factoringPermissionsAddress}`);

    const { bullaFactoringAddress, depositPermissionsAddress, factoringPermissionsAddress } = config;

    if (!depositPermissionsAddress || !factoringPermissionsAddress) {
        throw new Error('Missing permission contract addresses in network config');
    }

    // Grant Deposit and Factoring Permissions
    const depositPermissionsContract = new ethers.Contract(depositPermissionsAddress, depositPermissionsABI.abi, signer);
    const factoringPermissionsContract = new ethers.Contract(factoringPermissionsAddress, factoringPermissionsABI.abi, signer);

    let addressToApproveDeposit: string | undefined = await new Promise(resolve =>
        lineReader.question('deposit address to approve?: \n...\n', address => {
            resolve(address ? address : undefined);
        }),
    );
    if (!addressToApproveDeposit) {
        console.error('No address provided to approve. Please provide an address as a command-line argument.');
        return;
    }

    let addressToApproveFactoring: string | undefined = await new Promise(resolve =>
        lineReader.question('factoring address to approve?: \n...\n', address => {
            resolve(address ? address : undefined);
        }),
    );
    if (!addressToApproveFactoring) {
        console.error('No address provided to approve. Please provide an address as a command-line argument.');
        return;
    }

    await depositPermissionsContract.allow(addressToApproveDeposit);
    await factoringPermissionsContract.allow(addressToApproveFactoring);

    console.log('For the following Factoring Contract : \n', bullaFactoringAddress);
    console.log('Deposit Permissions granted to : \n', addressToApproveDeposit);
    console.log('Factoring Permissions granted to : \n', addressToApproveFactoring);
};

// Only run the function if this script is being executed directly
if (require.main === module) {
    updatePermissions()
        .then(() => process.exit(0))
        .catch(error => {
            console.error(error);
            process.exit(1);
        });
}
