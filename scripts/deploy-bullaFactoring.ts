import { writeFileSync } from 'fs';
import hre, { ethers } from 'hardhat';
import addresses from '../addresses.json';
import ERC20 from '../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json';
import bullaFactoringABI from '../deployments/sepolia/BullaFactoring.json';

const verifyContract = async (address: string, constructorArguments: any[], network: string) => {
    try {
        await hre.run('verify:verify', {
            address,
            constructorArguments,
            network,
        });
        console.log(`Contract verified: ${address}`);
    } catch (error: any) {
        if (error.message.includes('already verified')) {
            console.log(`Contract already verified: ${address}`);
        } else {
            throw error;
        }
    }
};

export const deployBullaFactoring = async function () {
    const { deployments, getNamedAccounts, getChainId } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    // deploy invoice provider contract
    // const bullaClaim = '0x3702D060cbB102b6AebF40B40880F77BeF3d7225'; // Sepolia Address
    // const { address: BullaClaimInvoiceProviderAdapterAddress } = await deploy('BullaClaimInvoiceProviderAdapter', {
    //     from: deployer,
    //     args: [bullaClaim],
    // });
    // Verify BullaClaimInvoiceProviderAdapter contract
    // await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], 'sepolia');

    const BullaClaimInvoiceProviderAdapterAddress = '0x595c0972b5d1e02c4a2f16480528733d912e4e48';
    console.log(`BullaClaimInvoiceProviderAdapter verified: ${BullaClaimInvoiceProviderAdapterAddress}`);

    // deploy mock permissions contract
    /*
    const { address: permissionsAddress } = await deploy('MockPermissions', {
        from: deployer,
        args: [],
    });
    await hre.run('verify:verify', {
        address: permissionsAddress,
        constructorArguments: [],
        network: 'sepolia',
    });
    console.log(`MockPermissions verified: ${permissionsAddress}`);
    */

    // use the current deployed mock permissions contract in order to use the granted permissions
    const permissionsAddress = '0xF388894046678081dFB02107dE53e03b4c474Adb';

    // deploy bulla factoring contract
    const mockUSDC = '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8'; // the USDC we use on bulla.network sepolia chain
    const chainId = await getChainId();
    const underwriter = '0x201D274192Fa7b21ce802f0b87D75Ae493A8C93D'; // Ben's address used in current underwriter function in backend
    const bullaDao = '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d'; // Mike's address
    const protocolFeeBps = 25;
    const adminFeeBps = 50;

    const { address: bullaFactoringAddress } = await deploy('BullaFactoring', {
        from: deployer,
        args: [
            mockUSDC,
            BullaClaimInvoiceProviderAdapterAddress,
            underwriter,
            permissionsAddress,
            permissionsAddress,
            bullaDao,
            protocolFeeBps,
            adminFeeBps,
        ],
    });

    // Set Impair Reserve and approve token
    const signer = await ethers.getSigner(deployer);
    const initialImpairReserve = 50000;
    const underlyingTokenContract = new ethers.Contract(mockUSDC, ERC20.abi, signer);
    await underlyingTokenContract.approve(bullaFactoringAddress, initialImpairReserve);

    const bullaFactoringContract = new ethers.Contract(bullaFactoringAddress, bullaFactoringABI.abi, signer);
    await bullaFactoringContract.setImpairReserve(initialImpairReserve);

    const newAddresses = {
        ...addresses,
        [chainId]: {
            ...(addresses[chainId as keyof typeof addresses] ?? {}),
            [bullaFactoringAddress]: {
                name: 'Bulla Factoring V1',
                bullaClaimInvoiceProviderAdapter: BullaClaimInvoiceProviderAdapterAddress,
                depositPermissions: permissionsAddress,
                factoringPermissions: permissionsAddress,
            },
        },
    };

    writeFileSync('./addresses.json', JSON.stringify(newAddresses, null, 2));

    const now = new Date();
    const deployInfo = {
        deployer,
        chainId: await getChainId(),
        currentTime: now.toISOString(),
        BullaClaimInvoiceProviderAdapterAddress,
        bullaFactoringAddress,
    };
    console.log('Bulla Invoice Invoice Provider Adapter Deployment Address: \n', BullaClaimInvoiceProviderAdapterAddress);
    console.log('Bulla Factoring Deployment Address: \n', bullaFactoringAddress);
    console.log('Permissions Address: \n', permissionsAddress);

    await verifyContract(
        bullaFactoringAddress,
        [
            mockUSDC,
            BullaClaimInvoiceProviderAdapterAddress,
            underwriter,
            permissionsAddress,
            permissionsAddress,
            bullaDao,
            protocolFeeBps,
            adminFeeBps,
        ],
        'sepolia',
    );
    console.log(`Contract verified: ${bullaFactoringAddress}`);

    return deployInfo;
};

// uncomment this line to run the script individually
deployBullaFactoring()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
