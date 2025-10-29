import { writeFileSync } from 'fs';
import automationAddresses from '../automation-addresses.json';
import { getChainId, getRpcUrl } from './network-config';
import { getPrivateKeyInteractively, runForgeScript, setupGracefulExit, validateNetwork } from './utils/interactive-deploy';
import { readLatestBroadcast, verifyBroadcastContracts } from './utils/verify-forge';

async function deployAutomationChecker(): Promise<void> {
    try {
        const network = validateNetwork(process.env.NETWORK);

        console.log(`🚀 Deploying BullaFactoringAutomationCheckerV2_1 to ${network}...\n`);

        const privateKey = await getPrivateKeyInteractively();
        const rpcUrl = getRpcUrl(network);

        const env: NodeJS.ProcessEnv = {
            ...process.env,
            NETWORK: network,
            PRIVATE_KEY: privateKey,
            DEPLOY_PK: privateKey,
        };

        const forgeProcess = runForgeScript(
            'script/DeployBullaFactoringAutomationChecker.s.sol:DeployBullaFactoringAutomationChecker',
            rpcUrl,
            privateKey,
            env,
            network,
        );

        forgeProcess.on('close', async code => {
            if (code === 0) {
                console.log('\n✅ Automation checker deployment completed successfully!');

                await verifyBroadcastContracts('DeployBullaFactoringAutomationChecker.s.sol', network, false);

                const broadcast = readLatestBroadcast('DeployBullaFactoringAutomationChecker.s.sol', network);
                if (broadcast) {
                    const deploymentTx = broadcast.transactions.find(
                        tx => tx.contractName === 'BullaFactoringAutomationCheckerV2_1' && tx.contractAddress,
                    );

                    if (deploymentTx?.contractAddress) {
                        const chainIdKey = getChainId(network).toString();
                        const updatedAddresses: Record<string, string> = {
                            ...(automationAddresses as Record<string, string>),
                            [chainIdKey]: deploymentTx.contractAddress,
                        };

                        writeFileSync('./automation-addresses.json', JSON.stringify(updatedAddresses, null, 2));
                        console.log(`💾 Updated automation-addresses.json with ${deploymentTx.contractAddress}`);
                    } else {
                        console.log('⚠️  Could not determine deployed contract address from broadcast file.');
                    }
                } else {
                    console.log('⚠️  No broadcast data available to update automation-addresses.json.');
                }

                console.log('\n📝 Next steps:');
                console.log('   1. Review automation-addresses.json for the deployed address.');
                console.log('   2. Confirm verification status on the block explorer.');
            } else {
                console.error(`\n❌ Automation checker deployment failed with exit code ${code}`);
                process.exit(code || 1);
            }
        });

        forgeProcess.on('error', error => {
            if ((error as any).code === 'ENOENT') {
                console.error('❌ Forge not found. Make sure Foundry is installed and in your PATH.');
                console.error('   Install from: https://getfoundry.sh/');
            } else {
                console.error('❌ Failed to start forge:', (error as Error).message);
            }
            process.exit(1);
        });
    } catch (error: any) {
        console.error('❌ Deployment error:', error.message);
        process.exit(1);
    }
}

setupGracefulExit();
deployAutomationChecker();
