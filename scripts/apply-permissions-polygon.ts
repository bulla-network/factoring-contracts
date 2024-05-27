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

    const bullaFactoringAddress = '0xb29218C74Bc6211092A288579be681187E21aFd8';
    const depositPermissionsAddress = '0x052E0d83BCeF4e75917Fcc10aB89D3F0F505926b';
    const factoringPermissionsAddress = '0x79B14C823A20DC5556A6922291020785B31274D5';

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
