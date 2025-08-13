import hre, { ethers } from 'hardhat';
import permissionsABI from '../artifacts/contracts/Permissions.sol/Permissions.json';
import { getNetworkFromEnv } from './deploy-utils';
import { getNetworkConfig } from './network-config';
import { ensurePrivateKey } from './private-key-utils';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    // Ensure we have a valid private key for deployment
    const privateKey = await ensurePrivateKey();
    const wallet = new ethers.Wallet(privateKey, ethers.provider);

    const { getNamedAccounts, getChainId } = hre;
    const { deployer } = await getNamedAccounts();
    const lineReader = getLineReader();

    console.log(`Applying permissions from address: ${wallet.address}`);

    // Get the network from environment variable
    const network = getNetworkFromEnv();
    console.log(`Using network: ${network}`);

    // Get the configuration for the specified network
    const config = getNetworkConfig(network);

    console.log(`Using addresses for ${network}:`);
    console.log(`- Bulla Factoring: ${config.bullaFactoringAddress || 'Not deployed yet'}`);
    console.log(`- Deposit Permissions: ${config.depositPermissionsAddress || 'Not deployed yet'}`);
    console.log(`- Factoring Permissions: ${config.factoringPermissionsAddress || 'Not deployed yet'}`);

    const { bullaFactoringAddress, depositPermissionsAddress, factoringPermissionsAddress } = config;

    // Check if addresses are available
    if (!bullaFactoringAddress || !depositPermissionsAddress || !factoringPermissionsAddress) {
        console.error('Some contract addresses are missing. Please deploy the contracts first.');
        return;
    }

    // Grant Deposit and Factoring Permissions
    const depositPermissionsContract = new ethers.Contract(depositPermissionsAddress, permissionsABI.abi, wallet);
    const factoringPermissionsContract = new ethers.Contract(factoringPermissionsAddress, permissionsABI.abi, wallet);

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
