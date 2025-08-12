// Script to estimate gas for contract deployments
import { TransactionRequest } from '@ethersproject/abstract-provider';
import { BigNumber, ContractFactory } from 'ethers';
import { ethers } from 'hardhat';

async function main(): Promise<void> {
    // Use 1 gwei for all cost calculations
    const gweiValue = 1;

    console.log('Estimating gas costs for contract deployments...');
    console.log(`Using ${gweiValue} gwei for all cost calculations`);

    // Get the contract factories
    const BullaFactoring: ContractFactory = await ethers.getContractFactory('BullaFactoring');
    const BullaFactoringAutomationChecker: ContractFactory = await ethers.getContractFactory('BullaFactoringAutomationChecker');
    const BullaClaimInvoiceProviderAdapter: ContractFactory = await ethers.getContractFactory('BullaClaimV2InvoiceProviderAdapterV2');
    const FactoringPermissions: ContractFactory = await ethers.getContractFactory('FactoringPermissions');
    const DepositPermissions: ContractFactory = await ethers.getContractFactory('DepositPermissions');

    // Get signers
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log(`Using deployer address: ${deployerAddress}`);

    // Example for FactoringPermissions contract
    // Custom Permissions contracts don't take constructor arguments
    const factoringPermissionsDeployTx: TransactionRequest = await FactoringPermissions.getDeployTransaction();
    const factoringPermissionsGasEstimate: BigNumber = await ethers.provider.estimateGas(factoringPermissionsDeployTx);
    console.log(`FactoringPermissions contract deployment gas estimate: ${factoringPermissionsGasEstimate.toString()}`);

    // Also estimate DepositPermissions
    const depositPermissionsDeployTx: TransactionRequest = await DepositPermissions.getDeployTransaction();
    const depositPermissionsGasEstimate: BigNumber = await ethers.provider.estimateGas(depositPermissionsDeployTx);
    console.log(`DepositPermissions contract deployment gas estimate: ${depositPermissionsGasEstimate.toString()}`);

    // Simulated deployment of BullaClaimV2InvoiceProviderAdapterV2
    // Replace with your actual constructor arguments
    try {
        const adapterDeployTx: TransactionRequest = await BullaClaimInvoiceProviderAdapter.getDeployTransaction(
            '0x1234567890123456789012345678901234567890', // _bullaClaimV2Address
            '0x1234567890123456789012345678901234567890', // _bullaFrendLend
            '0x1234567890123456789012345678901234567890', // _bullaInvoice
        );
        const adapterGasEstimate: BigNumber = await ethers.provider.estimateGas(adapterDeployTx);
        console.log(`BullaClaimV2InvoiceProviderAdapterV2 deployment gas estimate: ${adapterGasEstimate.toString()}`);

        // For BullaFactoring, you'll need to provide all the constructor parameters
        // This is a placeholder - replace with your actual parameters
        try {
            const factoringSampleArgs = [
                ethers.constants.AddressZero, // IERC20 _asset
                ethers.constants.AddressZero, // IInvoiceProviderAdapter
                deployerAddress, // _underwriter
                ethers.constants.AddressZero, // _depositPermissions
                ethers.constants.AddressZero, // _factoringPermissions
                deployerAddress, // _bullaDao
                200, // _protocolFeeBps (2%)
                300, // _adminFeeBps (3%)
                'Test Pool', // _poolName
                100, // _taxBps (1%)
                500, // _targetYieldBps (5%)
                'Test Token', // _tokenName
                'TEST', // _tokenSymbol
            ];

            const factoringDeployTx: TransactionRequest = await BullaFactoring.getDeployTransaction(...factoringSampleArgs);
            const factoringGasEstimate: BigNumber = await ethers.provider.estimateGas(factoringDeployTx);
            console.log(`BullaFactoring contract deployment gas estimate: ${factoringGasEstimate.toString()}`);

            // Calculate total with all contracts
            const totalEstimate: BigNumber = factoringPermissionsGasEstimate
                .add(depositPermissionsGasEstimate)
                .add(adapterGasEstimate)
                .add(factoringGasEstimate);

            console.log(`Total gas estimate: ${totalEstimate.toString()}`);
            console.log(
                `At ${gweiValue} gwei, this would cost approximately: ${ethers.utils.formatEther(
                    totalEstimate.mul(gweiValue).mul(1e9),
                )} ETH`,
            );
        } catch (error) {
            console.error('Error estimating BullaFactoring deployment:', (error as Error).message);

            // Calculate partial total (without BullaFactoring)
            const partialEstimate: BigNumber = factoringPermissionsGasEstimate.add(depositPermissionsGasEstimate).add(adapterGasEstimate);

            console.log(`Partial gas estimate (without BullaFactoring): ${partialEstimate.toString()}`);
            console.log(
                `At ${gweiValue} gwei, this would cost approximately: ${ethers.utils.formatEther(
                    partialEstimate.mul(gweiValue).mul(1e9),
                )} ETH`,
            );
        }
    } catch (error) {
        console.error('Error estimating adapter deployment:', (error as Error).message);

        // Calculate minimal total (only permissions contracts)
        const minimalEstimate: BigNumber = factoringPermissionsGasEstimate.add(depositPermissionsGasEstimate);
        console.log(`Minimal gas estimate (permissions only): ${minimalEstimate.toString()}`);
        console.log(
            `At ${gweiValue} gwei, this would cost approximately: ${ethers.utils.formatEther(minimalEstimate.mul(gweiValue).mul(1e9))} ETH`,
        );
    }
}

main()
    .then(() => process.exit(0))
    .catch((error: Error) => {
        console.error(error);
        process.exit(1);
    });
