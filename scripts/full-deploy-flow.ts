import { deployAdapterWorkflow } from './deploy-adapter';
import { deployFactoringWorkflow } from './deploy-bullaFactoring';
import { getPrivateKeyInteractively, setupGracefulExit } from './utils/interactive-deploy';
import { getNetworkAndPoolInteractive } from './utils/interactive-prompt';
import { verifyAllContractsWorkflow } from './verify-all-contracts';
import { whitelistCallbackWorkflow } from './whitelist-callback';

/**
 * Full deployment flow: Deploy everything and set up configurations
 */
async function fullDeployFlow(): Promise<void> {
    console.log('╔═══════════════════════════════════════════════════════════╗');
    console.log('║        🚀 FULL FACTORING DEPLOYMENT FLOW 🚀              ║');
    console.log('╚═══════════════════════════════════════════════════════════╝\n');

    try {
        // Get network, pool, and private key once at the start
        const { network, pool } = await getNetworkAndPoolInteractive();
        const privateKey = await getPrivateKeyInteractively();

        console.log('\n═══════════════════════════════════════════════════════════');
        console.log('📋 Deployment Configuration:');
        console.log(`   Network: ${network}`);
        console.log(`   Pool: ${pool}`);
        console.log('═══════════════════════════════════════════════════════════\n');

        // Step 1: Deploy Adapter
        console.log('📦 STEP 1/4: Deploying Invoice Provider Adapter...');
        console.log('───────────────────────────────────────────────────────────');
        await deployAdapterWorkflow(network, privateKey);

        // Wait a bit between deployments
        await new Promise(resolve => setTimeout(resolve, 2000));

        // Step 2: Deploy BullaFactoring
        console.log('\n📦 STEP 2/4: Deploying BullaFactoring Contracts...');
        console.log('───────────────────────────────────────────────────────────');
        await deployFactoringWorkflow(network, pool, privateKey);

        // Wait a bit between deployments
        await new Promise(resolve => setTimeout(resolve, 2000));

        // Step 3: Verify Contracts
        console.log('\n🔍 STEP 3/4: Verifying Deployed Contracts...');
        console.log('───────────────────────────────────────────────────────────');
        await verifyAllContractsWorkflow(network);

        // Step 4: Whitelist Callbacks
        console.log('\n🔐 STEP 4/4: Whitelisting Callbacks...');
        console.log('───────────────────────────────────────────────────────────');
        await whitelistCallbackWorkflow(network, pool, privateKey);

        // Success!
        console.log('\n╔═══════════════════════════════════════════════════════════╗');
        console.log('║              ✅ DEPLOYMENT COMPLETED! ✅                  ║');
        console.log('╚═══════════════════════════════════════════════════════════╝\n');

        console.log('🎉 Full deployment flow completed successfully!');
        console.log(`\n📝 Deployed on ${network}/${pool}:`);
        console.log('   ✅ Invoice Provider Adapter');
        console.log('   ✅ BullaFactoring Contract');
        console.log('   ✅ Factoring Permissions');
        console.log('   ✅ Deposit Permissions');
        console.log('   ✅ Contract Verification');
        console.log('   ✅ Callback Whitelisting');

        console.log('\n📋 Next Steps:');
        console.log('   1. Check network-config.ts for all deployed addresses');
        console.log('   2. Test deposit/withdraw functionality');
        console.log('   3. Approve and fund test invoices');
        console.log('   4. Monitor contract interactions on block explorer\n');
    } catch (error: any) {
        console.error('\n╔═══════════════════════════════════════════════════════════╗');
        console.error('║              ❌ DEPLOYMENT FAILED ❌                      ║');
        console.error('╚═══════════════════════════════════════════════════════════╝\n');
        console.error('❌ Error:', error.message);
        console.error('\n💡 You can retry individual steps using the specific deployment scripts.');
        process.exit(1);
    }
}

// Setup graceful exit handling
setupGracefulExit();

// Run the full deployment flow
fullDeployFlow();
