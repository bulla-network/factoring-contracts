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

    const BullaClaimInvoiceProviderAdapterAddress = '0x15ef2BD80BE2247C9007A35c761Ea9aDBe1063C5';
    // await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], 'sepolia');

    // console.log(`BullaClaimInvoiceProviderAdapter verified: ${BullaClaimInvoiceProviderAdapterAddress}`);

    // deploy mock permissions contracts for deposit and factoring
    // const { address: depositPermissionsAddress } = await deploy('MockPermissions', {
    //     from: deployer,
    //     args: [],
    // });
    // await hre.run('verify:verify', {
    //     address: depositPermissionsAddress,
    //     constructorArguments: [],
    //     network: 'sepolia',
    // });
    // console.log(`MockDepositPermissionsAddress verified: ${depositPermissionsAddress}`);

    // const { address: factoringPermissionsAddress } = await deploy('MockPermissions', {
    //     from: deployer,
    //     args: [],
    // });

    // await hre.run('verify:verify', {
    //     address: factoringPermissionsAddress,
    //     constructorArguments: [],
    //     network: 'sepolia',
    // });
    // console.log(`MockFactoringPermissionsAddresss verified: ${factoringPermissionsAddress}`);

    // use the current deployed mocks permissions contract for both factoring and depositing in order to use the granted permissions for the appropriate safes
    const factoringPermissionsAddress = '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e';
    // await verifyContract(factoringPermissionsAddress, [], 'sepolia');
    const depositPermissionsAddress = '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8';
    // await verifyContract(depositPermissionsAddress, [], 'sepolia');

    // deploy bulla factoring contract
    const mockUSDC = '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8'; // the USDC we use on bulla.network sepolia chain
    const chainId = await getChainId();
    const underwriter = '0x201D274192Fa7b21ce802f0b87D75Ae493A8C93D'; // Ben's address used in current underwriter function in backend
    const bullaDao = '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d'; // Mike's address
    const protocolFeeBps = 25;
    const adminFeeBps = 50;
    const poolName = 'Bulla TCS Factoring Pool';
    const taxBps = 10;
    const targetYieldBps = 730;
    const poolTokenName = 'Bulla TCS Factoring Pool';
    const poolTokenSymbol = 'BFT-TCS';

    // const { address: bullaFactoringAddress } = await deploy('BullaFactoring', {
    //     from: deployer,
    //     args: [
    //         mockUSDC,
    //         BullaClaimInvoiceProviderAdapterAddress,
    //         underwriter,
    //         depositPermissionsAddress,
    //         factoringPermissionsAddress,
    //         bullaDao,
    //         protocolFeeBps,
    //         adminFeeBps,
    //         poolName,
    //         taxBps,
    //         targetYieldBps,
    //         poolTokenName,
    //         poolTokenSymbol,
    //     ],
    // });

    const bullaFactoringAddress = '0x2371A9F2c103f8f546a969109B350d6A13d0851B';

    // Set Impair Reserve and approve token
    // const signer = await ethers.getSigner(deployer);
    // const initialImpairReserve = 50000;
    // const underlyingTokenContract = new ethers.Contract(mockUSDC, ERC20.abi, signer);
    // await underlyingTokenContract.approve(bullaFactoringAddress, initialImpairReserve);

    // const bullaFactoringContract = new ethers.Contract(bullaFactoringAddress, bullaFactoringABI.abi, signer);
    // await bullaFactoringContract.setImpairReserve(initialImpairReserve);

    // const impairReserve = await bullaFactoringContract.impairReserve();
    // console.log('Bulla Factoring Impair Reserve Set to: \n', impairReserve);

    // const newAddresses = {
    //     ...addresses,
    //     [chainId]: {
    //         ...(addresses[chainId as keyof typeof addresses] ?? {}),
    //         [bullaFactoringAddress]: {
    //             name: 'Bulla TCS Factoring Pool',
    //             bullaClaimInvoiceProviderAdapter: BullaClaimInvoiceProviderAdapterAddress,
    //             depositPermissions: depositPermissionsAddress,
    //             factoringPermissions: factoringPermissionsAddress,
    //         },
    //     },
    // };

    // writeFileSync('./addresses.json', JSON.stringify(newAddresses, null, 2));

    // const now = new Date();
    // const deployInfo = {
    //     deployer,
    //     chainId: await getChainId(),
    //     currentTime: now.toISOString(),
    //     BullaClaimInvoiceProviderAdapterAddress,
    //     bullaFactoringAddress,
    // };
    console.log('Bulla Invoice Invoice Provider Adapter Deployment Address: \n', BullaClaimInvoiceProviderAdapterAddress);
    console.log('Bulla Factoring Deployment Address: \n', bullaFactoringAddress);
    console.log('Deposit Permissions Address: \n', depositPermissionsAddress);
    console.log('Factoring Permissions Address: \n', factoringPermissionsAddress);

    // await verifyContract(
    //     bullaFactoringAddress,
    //     [
    //         mockUSDC,
    //         BullaClaimInvoiceProviderAdapterAddress,
    //         underwriter,
    //         depositPermissionsAddress,
    //         factoringPermissionsAddress,
    //         bullaDao,
    //         protocolFeeBps,
    //         adminFeeBps,
    //         poolName,
    //         taxBps,
    //         targetYieldBps,
    //         poolTokenName,
    //         poolTokenSymbol,
    //     ],
    //     'sepolia',
    // );
    // console.log(`Bulla Factoring Contract verified: ${bullaFactoringAddress}`);

    // return deployInfo;
};

// uncomment this line to run the script individually
deployBullaFactoring()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
