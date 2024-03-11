import { readFileSync, writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import addresses from '../addresses.json';
import permissionsABI from '../deployments/sepolia/MockPermissions.json';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    const { getNamedAccounts, getChainId } = hre;
    const { deployer } = await getNamedAccounts();
    const lineReader = getLineReader();
    const signer = await ethers.getSigner(deployer);

    const bullaFactoringAddress = '0x5e94a4fF11C82D1E1DF912E40658718e95c7f990';
    const depositPermissionsAddress = '0xF388894046678081dFB02107dE53e03b4c474Adb';
    const factoringPermissionsAddress = '0xF388894046678081dFB02107dE53e03b4c474Adb';

    // Grant Deposit and Factoring Permissions
    const depositPermissionsContract = new ethers.Contract(depositPermissionsAddress, permissionsABI.abi, signer);
    const factoringPermissionsContract = new ethers.Contract(factoringPermissionsAddress, permissionsABI.abi, signer);

    let addressToApprove: string | undefined = await new Promise(resolve =>
        lineReader.question('address to approve?: \n...\n', address => {
            resolve(address ? address : undefined);
        }),
    );
    if (!addressToApprove) {
        console.error('No address provided to approve. Please provide an address as a command-line argument.');
        return;
    }

    await depositPermissionsContract.allow(addressToApprove);
    await factoringPermissionsContract.allow(addressToApprove);

    console.log('For the following Factoring Contract : \n', bullaFactoringAddress);
    console.log('Deposit Permissions granted to : \n', addressToApprove);
    console.log('Factoring Permissions granted to : \n', addressToApprove);
};

// uncomment this line to run the script individually
updatePermissions()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
