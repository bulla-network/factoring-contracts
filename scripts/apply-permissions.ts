import hre, { ethers } from 'hardhat';
import permissionsABI from '../artifacts/contracts/Permissions.sol/Permissions.json';
import { getNetworkConfig } from './network-config';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    const { getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const lineReader = getLineReader();
    const signer = await ethers.getSigner(deployer);

    // Get the network from environment variable
    const network = process.env.NETWORK;
    if (!network) {
        console.error('Please provide a network as an environment variable');
        process.exit(1);
    }

    console.log(`Using network: ${network}`);

    // Get the configuration for the specified network
    const config = getNetworkConfig(network);

    console.log(`Using addresses for ${network}:`);
    console.log(`- Bulla Factoring: ${config.bullaFactoringAddress}`);
    console.log(`- Deposit Permissions: ${config.depositPermissionsAddress}`);
    console.log(`- Factoring Permissions: ${config.factoringPermissionsAddress}`);

    const { bullaFactoringAddress, depositPermissionsAddress, factoringPermissionsAddress } = config;

    // Grant Deposit and Factoring Permissions
    const depositPermissionsContract = new ethers.Contract(depositPermissionsAddress, permissionsABI.abi, signer);
    const factoringPermissionsContract = new ethers.Contract(factoringPermissionsAddress, permissionsABI.abi, signer);

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

// uncomment this line to run the script individually
updatePermissions()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
