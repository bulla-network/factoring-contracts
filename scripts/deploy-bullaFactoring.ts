import { writeFileSync } from 'fs';
import hre from 'hardhat';
import addresses from '../addresses.json';

export const deployBullaFactoring = async function () {
    const { deployments, getNamedAccounts, getChainId } = hre;
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    // deploy invoice provider contract
    const bullaClaim = '0x3702D060cbB102b6AebF40B40880F77BeF3d7225'; // Sepolia Address
    const { address: BullaClaimInvoiceProviderAdapterAddress } = await deploy('BullaClaimInvoiceProviderAdapter', {
        from: deployer,
        args: [bullaClaim],
    });

    // deploy mock permissions contract
    const { address: permissionsAddress } = await deploy('MockPermissions', {
        from: deployer,
        args: [],
    });

    // deploy bulla factoring contract
    const mockUSDC = '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8'; // the USDC we use on bulla.network sepolia chain
    const chainId = await getChainId();
    const underwriter = deployer; // TBD

    const { address: bullaFactoringAddress } = await deploy('BullaFactoring', {
        from: deployer,
        args: [mockUSDC, BullaClaimInvoiceProviderAdapterAddress, underwriter, permissionsAddress, permissionsAddress],
    });

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

    return deployInfo;
};

// uncomment this line to run the script individually
deployBullaFactoring()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
