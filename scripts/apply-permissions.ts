import { readFileSync, writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import addresses from '../addresses.json';
import permissionsABI from '../artifacts/contracts/Permissions.sol/Permissions.json';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    const { getNamedAccounts, getChainId } = hre;
    const { deployer } = await getNamedAccounts();
    const lineReader = getLineReader();
    const signer = await ethers.getSigner(deployer);

    const bullaFactoringAddress = '0xE0C27578a2cd31e4Ea92a3b0BDB2873CCd763242';
    const depositPermissionsAddress = '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8';
    const factoringPermissionsAddress = '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e';

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
