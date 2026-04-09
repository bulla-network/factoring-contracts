import { getAvailablePools, getDeployedPoolConfig, getNetworkOnlyConfig, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkInteractive } from './utils/interactive-prompt';
import { updateAgreementSignatureRepoFromBroadcast } from './utils/update-config';
import { verifyBroadcastContracts } from './utils/verify-forge';

function getUnderwriterAddress(network: string): string {
    const pools = getAvailablePools(network);
    for (const pool of pools) {
        const poolConfig = getDeployedPoolConfig(network, pool);
        if (poolConfig?.underwriter) {
            return poolConfig.underwriter;
        }
    }
    throw new Error(`No deployed pool with an underwriter found on network '${network}'`);
}

/**
 * Deploy AgreementSignatureRepo workflow (can be called with parameters or standalone)
 */
export async function deployAgreementSignatureRepoWorkflow(network: string, privateKey: string): Promise<void> {
    console.log(`🚀 Deploying AgreementSignatureRepo to ${network} network...\n`);

    // Get network configuration
    const config = getNetworkOnlyConfig(network);

    // Check if already deployed
    if (
        config.agreementSignatureRepoAddress &&
        config.agreementSignatureRepoAddress !== '0x0000000000000000000000000000000000000000'
    ) {
        console.log('⚠️  AgreementSignatureRepo already deployed on this network:');
        console.log(`   Address: ${config.agreementSignatureRepoAddress}`);
        console.log('   Skipping deployment.\n');
        return;
    }

    // Use the underwriter address as the initial signature approver
    const initialSignatureApprover = getUnderwriterAddress(network);

    // Display deployment info
    console.log('📋 Deployment Configuration:');
    console.log(`   Initial Signature Approver (underwriter): ${initialSignatureApprover}\n`);

    console.log(`📡 Starting AgreementSignatureRepo deployment to ${network}...\n`);

    // Get RPC URL using shared config
    const rpcUrl = getRpcUrl(network);

    // Set environment variables for the deployment script
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        NETWORK: network,
        PRIVATE_KEY: privateKey,
        DEPLOY_PK: privateKey,
        INITIAL_SIGNATURE_APPROVER: initialSignatureApprover,
    };

    // Run forge script and wait for completion
    await new Promise<void>((resolve, reject) => {
        const forgeProcess = runForgeScript(
            'script/DeployAgreementSignatureRepo.s.sol:DeployAgreementSignatureRepo',
            rpcUrl,
            privateKey,
            env,
            network,
        );

        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ AgreementSignatureRepo deployment completed successfully!');
                console.log(`🎉 Your AgreementSignatureRepo is now live on ${network}!`);

                // Update network config with new address
                console.log('\n📝 Updating network-config.ts...');
                updateAgreementSignatureRepoFromBroadcast('DeployAgreementSignatureRepo.s.sol', network);

                // Verify contracts using broadcast files
                await verifyBroadcastContracts('DeployAgreementSignatureRepo.s.sol', network, false);

                console.log('\n📝 Next steps:');
                console.log('   1. Check network-config.ts for the updated AgreementSignatureRepo address');
                console.log('   2. Contract verification has been attempted automatically');
                console.log('   3. Configure the signature approver if needed');

                resolve();
            } else {
                reject(new Error(`AgreementSignatureRepo deployment failed with exit code ${code}`));
            }
        });

        forgeProcess.on('error', error => {
            if ((error as any).code === 'ENOENT') {
                reject(new Error('Forge not found. Make sure Foundry is installed and in your PATH.'));
            } else {
                reject(error);
            }
        });
    });
}

/**
 * Launcher: Get network and private key interactively, then run workflow
 */
async function deployAgreementSignatureRepoLauncher(): Promise<void> {
    try {
        const network = await getNetworkInteractive();
        const privateKey = await getPrivateKeyInteractively();

        await deployAgreementSignatureRepoWorkflow(network, privateKey);
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

// Only run launcher if this script is run directly
if (require.main === module) {
    setupGracefulExit();
    deployAgreementSignatureRepoLauncher();
}
