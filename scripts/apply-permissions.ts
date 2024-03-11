import { readFileSync, writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import addresses from '../addresses.json';
import permissionsABI from '../deployments/sepolia/MockPermissions.json';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    const { getNamedAccounts, getChainId } = hre;
    const { deployer } = await getNamedAccounts();
    const chainId = await getChainId();
    const lineReader = getLineReader();
    const signer = await ethers.getSigner(deployer);

    const bullaFactoringAddress = '0x5e94a4fF11C82D1E1DF912E40658718e95c7f990';

    const addresses = JSON.parse(readFileSync('./addresses.json', { encoding: 'utf-8' }));

    const factoringAddresses = addresses[chainId][bullaFactoringAddress];

    // Ensure the bullaFactoringAddress exists for the chainId
    if (!factoringAddresses) {
        console.log('Factoring Address not found: ', bullaFactoringAddress);
        return;
    }

    // Deposit Permissions Granted
    const depositPermissionsContract = new ethers.Contract(factoringAddresses.depositPermissions, permissionsABI.abi, signer);
    const factoringPermissionsContract = new ethers.Contract(factoringAddresses.depositPermissions, permissionsABI.abi, signer);

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

    const depositApprovedAddresses = addresses[chainId][bullaFactoringAddress].depositApprovedAddresses || [];
    if (!depositApprovedAddresses.includes(addressToApprove)) {
        depositApprovedAddresses.push(addressToApprove);
    }

    const factoringApprovedAddresses = addresses[chainId][bullaFactoringAddress].factoringApprovedAddresses || [];
    if (!factoringApprovedAddresses.includes(addressToApprove)) {
        factoringApprovedAddresses.push(addressToApprove);
    }

    // Assign the updated arrays back to the addresses object
    addresses[chainId][bullaFactoringAddress].depositApprovedAddresses = depositApprovedAddresses;
    addresses[chainId][bullaFactoringAddress].factoringApprovedAddresses = factoringApprovedAddresses;

    // Write the updated addresses back to the file
    writeFileSync('./addresses.json', JSON.stringify(addresses, null, 2));

    const scriptInfo = {
        bullaFactoringAddress,
        depositApprovedAddresses,
        factoringApprovedAddresses,
    };

    console.log('For the following Factoring Contract : \n', bullaFactoringAddress);

    console.log('Deposit Permissions granted to : \n', depositApprovedAddresses);
    console.log('Factoring Permissions granted to : \n', factoringApprovedAddresses);
    return scriptInfo;
};

// uncomment this line to run the script individually
updatePermissions()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
