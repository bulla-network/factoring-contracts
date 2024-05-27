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
    // const bullaClaim = '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4'; // Polygon Address
    // const { address: BullaClaimInvoiceProviderAdapterAddress } = await deploy('BullaClaimInvoiceProviderAdapter', {
    //     from: deployer,
    //     args: [bullaClaim],
    // });

    const BullaClaimInvoiceProviderAdapterAddress = '0xB5B31E95f0C732450Bc869A6467A9941C8565b10';
    // Verify BullaClaimInvoiceProviderAdapter contract
    // await verifyContract(BullaClaimInvoiceProviderAdapterAddress, [bullaClaim], 'polygon');

    // console.log(`BullaClaimInvoiceProviderAdapter verified: ${BullaClaimInvoiceProviderAdapterAddress}`);

    // deploy mock permissions contracts for deposit and factoring
    // const { address: depositPermissionsAddress } = await deploy('MockDepositPermissions', {
    //     from: deployer,
    //     args: [],
    // });
    // await hre.run('verify:verify', {
    //     address: depositPermissionsAddress,
    //     constructorArguments: [],
    //     network: 'polygon',
    // });
    // console.log(`MockDepositPermissionsAddress verified: ${depositPermissionsAddress}`);

    // const { address: factoringPermissionsAddress } = await deploy('MockFactoringPermissions', {
    //     from: deployer,
    //     args: [],
    // });

    // use the current deployed mocks permissions contract for both factoring and depositing in order to use the granted permissions for the appropriate safes
    const factoringPermissionsAddress = '0x79B14C823A20DC5556A6922291020785B31274D5';

    // await hre.run('verify:verify', {
    //     address: factoringPermissionsAddress,
    //     constructorArguments: [],
    //     network: 'polygon',
    //     contract: 'contracts/mocks/MockFactoringPermissions.sol:MockFactoringPermissions',
    // });
    // console.log(`MockFactoringPermissionsAddresss verified: ${factoringPermissionsAddress}`);
    // await verifyContract(factoringPermissionsAddress, [], 'polygon');
    const depositPermissionsAddress = '0x052E0d83BCeF4e75917Fcc10aB89D3F0F505926b';
    // await verifyContract(depositPermissionsAddress, [], 'polygon');

    // deploy bulla factoring contract
    const underlyingAsset = '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359'; // USDC on polygon, also used in Bulla Banker
    const chainId = await getChainId();
    const underwriter = '0x201D274192Fa7b21ce802f0b87D75Ae493A8C93D'; // Ben's address used in current underwriter function in backend
    const bullaDao = '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d'; // Mike's address
    const protocolFeeBps = 25;
    const adminFeeBps = 50;
    const poolName = 'Bulla TCS Factoring Pool - Polygon V0 Test';
    const taxBps = 10;
    const targetYieldBps = 730;
    const poolTokenName = 'Bulla TCS Factoring Pool';
    const poolTokenSymbol = 'BFT-TCS';

    // const { address: bullaFactoringAddress } = await deploy('BullaFactoring', {
    //     from: deployer,
    //     args: [
    //         underlyingAsset,
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

    const bullaFactoringAddress = '0xb29218C74Bc6211092A288579be681187E21aFd8';

    // Set Impair Reserve and approve token
    // const signer = await ethers.getSigner(deployer);
    // const initialImpairReserve = 50000;
    // const underlyingTokenContract = new ethers.Contract(underlyingAsset, ERC20.abi, signer);
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
    //             name: poolName,
    //             bullaClaimInvoiceProviderAdapter: BullaClaimInvoiceProviderAdapterAddress,
    //             depositPermissions: depositPermissionsAddress,
    //             factoringPermissions: factoringPermissionsAddress,
    //         },
    //     },
    // };

    // writeFileSync('./addresses.json', JSON.stringify(newAddresses, null, 2));

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
    console.log('Deposit Permissions Address: \n', depositPermissionsAddress);
    console.log('Factoring Permissions Address: \n', factoringPermissionsAddress);

    // await verifyContract(
    //     bullaFactoringAddress,
    //     [
    //         underlyingAsset,
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
    //     'polygon',
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
