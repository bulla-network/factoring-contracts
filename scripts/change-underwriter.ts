import hre, { ethers } from 'hardhat';
import bullaFactoringABI from '../deployments/sepolia/BullaFactoring.json';
import { getLineReader } from './utils';

export const updatePermissions = async function () {
    const { getNamedAccounts } = hre;
    const { deployer } = await getNamedAccounts();
    const lineReader = getLineReader();
    const signer = await ethers.getSigner(deployer);

    const bullaFactoringAddress = '0x5e94a4fF11C82D1E1DF912E40658718e95c7f990';

    const bullaFactoringContract = new ethers.Contract(bullaFactoringAddress, bullaFactoringABI.abi, signer);

    let newUnderwriterAddress: string | undefined = await new Promise(resolve =>
        lineReader.question('change underwriter to which address?: \n...\n', address => {
            resolve(address ? address : undefined);
        }),
    );
    if (!newUnderwriterAddress) {
        console.error('No address provided. Please provide an address as a command-line argument.');
        return;
    }

    await bullaFactoringContract.setUnderwriter(newUnderwriterAddress);

    console.log('For the following Factoring Contract : \n', bullaFactoringAddress);
    console.log('New underwriter is : \n', newUnderwriterAddress);
};

// uncomment this line to run the script individually
updatePermissions()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
