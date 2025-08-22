import hre from 'hardhat';
import { taramRedbellyConfig } from './scripts/network-config';
import { verifyFromAddresses } from './scripts/verify-bullaFactoring';

async function main() {
    const bullaFactoringAddress = '0x8f5952d2122A8DF42a3dcB5286D7576ff640cF5D';
    const network = 'redbelly';

    console.log('🔍 === VERIFICATION DETAILS ===');
    console.log(`📡 Target Network: ${network}`);
    console.log(`📋 BullaFactoring Address: ${bullaFactoringAddress}`);

    // Get hardhat network configuration
    const hardhatNetwork = hre.network;
    console.log(`\n⚙️  === HARDHAT NETWORK CONFIGURATION ===`);
    console.log(`🏷️  Hardhat Network Name: ${hardhatNetwork.name}`);
    console.log(`🔗 Chain ID: ${await hre.getChainId()}`);

    if (hardhatNetwork.config) {
        console.log(`🌐 RPC URL: ${hardhatNetwork.config.url || 'Not configured'}`);
        console.log(`⛽ Gas Price: ${hardhatNetwork.config.gasPrice || 'Auto'}`);
        console.log(`📊 Gas Limit: ${hardhatNetwork.config.gas || 'Auto'}`);

        if (hardhatNetwork.config.accounts && Array.isArray(hardhatNetwork.config.accounts)) {
            console.log(`🔐 Number of Accounts: ${hardhatNetwork.config.accounts.length}`);
        }
    }

    // Show network-specific configuration
    console.log(`\n📝 === REDBELLY NETWORK CONFIGURATION ===`);
    console.log(`🏪 BullaClaim Address: ${taramRedbellyConfig.bullaClaim}`);
    console.log(`💰 Underlying Asset (USDC.e): ${taramRedbellyConfig.underlyingAsset}`);
    console.log(`🏦 Underwriter: ${taramRedbellyConfig.underwriter}`);
    console.log(`🏛️  BullaDAO: ${taramRedbellyConfig.bullaDao}`);
    console.log(`📊 Protocol Fee (bps): ${taramRedbellyConfig.protocolFeeBps}`);
    console.log(`🔧 Admin Fee (bps): ${taramRedbellyConfig.adminFeeBps}`);
    console.log(`🏊 Pool Name: ${taramRedbellyConfig.poolName}`);
    console.log(`🎯 Target Yield (bps): ${taramRedbellyConfig.targetYieldBps}`);
    console.log(`🪙  Pool Token: ${taramRedbellyConfig.poolTokenName} (${taramRedbellyConfig.poolTokenSymbol})`);
    console.log(`🔄 Uses Permissions with Reconcile: ${taramRedbellyConfig.usePermissionsWithReconcile}`);

    // Show etherscan configuration for this network
    console.log(`\n🔍 === ETHERSCAN VERIFICATION CONFIGURATION ===`);
    const etherscanConfig = hre.config.etherscan;
    if (etherscanConfig && etherscanConfig.customChains) {
        const redbellyChain = etherscanConfig.customChains.find(chain => chain.network === 'redbelly');
        if (redbellyChain) {
            console.log(`🌐 Chain ID: ${redbellyChain.chainId}`);
            console.log(`📡 API URL: ${redbellyChain.urls.apiURL}`);
            console.log(`🌍 Browser URL: ${redbellyChain.urls.browserURL}`);
        }
    }

    console.log(`\n🚀 === STARTING VERIFICATION PROCESS ===\n`);

    try {
        const results = await verifyFromAddresses(bullaFactoringAddress, network);
        const allVerified = Object.values(results).every(Boolean);

        console.log(`\n✨ === FINAL STATUS ===`);
        console.log(`🎯 All contracts verified: ${allVerified ? '✅ YES' : '❌ NO'}`);

        process.exit(allVerified ? 0 : 1);
    } catch (error: any) {
        console.error('\n💥 === VERIFICATION FAILED ===');
        console.error(`❌ Error: ${error.message}`);
        if (error.stack) {
            console.error(`📋 Stack trace: ${error.stack}`);
        }
        process.exit(1);
    }
}

main().catch(console.error);
