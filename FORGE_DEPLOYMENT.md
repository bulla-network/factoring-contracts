# Forge-Based Deployment Guide

This project now supports Forge-based deployments as an alternative to Hardhat, following the pattern used in [bulla-contracts-V2](https://github.com/bulla-network/bulla-contracts-V2).

## Benefits of Forge Deployment

-   ✅ **No Import Issues**: Native support for Foundry remappings and `bulla-contracts-v2` imports
-   ✅ **Faster Compilation**: Forge compiles Solidity much faster than Hardhat
-   ✅ **Better Gas Estimation**: More accurate gas estimates and optimization
-   ✅ **Simpler Configuration**: No need for complex remapping configurations
-   ✅ **Native Verification**: Built-in contract verification with proper constructor args

## Available Scripts

### 🔐 Simple TypeScript Deployment

**One deployment method: Interactive private key prompt + Forge deployment + Automatic verification.** You'll be prompted to enter your private key during deployment, ensuring it's never stored in files or environment variables. After successful deployment, contracts are automatically verified on block explorers.

#### Full Deployment (All Contracts)

Deploy the complete BullaFactoring ecosystem:

```bash
# Sepolia
yarn deploy:sepolia

# Polygon
yarn deploy:polygon

# Mainnet
yarn deploy:mainnet

# Fundora on Sepolia (uses Sepolia network with Fundora-specific config)
yarn deploy:fundora-sepolia
```

### Adapter-Only Deployment

Deploy just the `BullaClaimV2InvoiceProviderAdapterV2` contract:

```bash
# Sepolia
yarn deploy:adapter:sepolia

# Polygon
yarn deploy:adapter:polygon

# Mainnet
yarn deploy:adapter:mainnet

# Fundora on Sepolia
yarn deploy:adapter:fundora-sepolia
```

### Contract Verification

Verify deployed contracts using broadcast files:

```bash
# Verify ALL deployed contracts across ALL broadcasts and networks
# (This finds every deployment in the broadcast/ folder)
yarn verify:all

# Verify all contracts for a specific network (across all broadcasts)
yarn verify:sepolia
yarn verify:polygon
yarn verify:mainnet
yarn verify:fundora-sepolia
```

**How verification works:**

### Verification Strategy

The verification system has two modes:

1. **Latest Broadcast Only** (used during deployment):

    - Only verifies contracts from the most recent deployment (`run-latest.json`)
    - Used by `deploy:*` scripts after successful deployment

2. **All Broadcasts** (used by standalone verification):
    - Scans all `run-*.json` files in the broadcast directory
    - Verifies every unique contract that has ever been deployed
    - Deduplicates by contract address to avoid re-verifying the same contract
    - Used by `verify:*` scripts

**Technical details:**

-   📁 Scans `broadcast/` folder for all deployment files
-   🔍 Automatically detects deployed contracts from broadcast JSON files
-   🌐 Maps chain IDs to networks (1=mainnet, 137=polygon, 11155111=sepolia)
-   ⚡ Uses correct compiler version (v0.8.30) and optimization settings
-   🔒 Deduplicates contracts to avoid re-verification
-   🔄 Includes rate limiting to avoid API throttling
-   🛡️ Non-blocking: verification failures don't stop the process

### Fallback to Hardhat (if needed)

The original Hardhat deployment scripts are still available:

```bash
yarn deploy:sepolia:hardhat
yarn deploy:polygon:hardhat
yarn deploy:mainnet:hardhat
```

## How It Works

### 1. Solidity Scripts (`script/` directory)

-   `DeployBullaFactoring.s.sol` - Full deployment script
-   `DeployAdapter.s.sol` - Adapter-only deployment script

### 2. Unified TypeScript Architecture

**Clean TypeScript deployment scripts:**

-   **`scripts/deploy-bullaFactoring.ts`** - Complete factoring ecosystem deployment
-   **`scripts/deploy-adapter.ts`** - Standalone adapter deployment
-   **`scripts/utils/interactive-deploy.ts`** - Shared utilities (prompting, validation, forge execution)
-   **`scripts/network-config.ts`** - Single source of truth for all network configurations

This eliminates redundant configuration and ensures type safety across all deployment scripts.

## Environment Variables Required

Make sure your `.env` file contains:

```bash
# Network-specific RPC endpoints
INFURA_API_KEY=your_infura_key
MAINNET_GETBLOCK_API_KEY=your_getblock_key

# For contract verification
ETHERSCAN_API_KEY=your_etherscan_key
POLYGONSCAN_API_KEY=your_polygonscan_key
```

## Features Preserved

All existing features from the Hardhat deployment are preserved:

-   ✅ Network-specific configuration loading
-   ✅ Automatic contract verification
-   ✅ `addresses.json` file updates
-   ✅ Impair reserve setting
-   ✅ Gas usage reporting
-   ✅ Deployment summaries
-   ✅ Error handling and rollback

## Contract Deployment Order

1. **BullaClaimV2InvoiceProviderAdapterV2** (if not provided)
2. **FactoringPermissions** (if not provided)
3. **DepositPermissions** (if not provided)
4. **BullaFactoring** (main contract)
5. **Post-deployment**: Set impair reserve, verify contracts

## Verification

Contracts are automatically verified on Etherscan/Polygonscan with proper constructor arguments. The verification includes:

-   Source code upload
-   Constructor argument encoding
-   Contract name resolution
-   Compilation settings matching

## Migration from Hardhat

To switch from Hardhat to Forge deployment:

1. **Test the adapter deployment first**:

    ```bash
    yarn deploy:adapter:sepolia
    ```

2. **Run full deployment**:

    ```bash
    yarn deploy:sepolia
    ```

3. **Verify addresses.json is updated correctly**

4. **Update your CI/CD scripts** to use the new commands

## Troubleshooting

### Common Issues

1. **"forge not found"** - Install Foundry: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

2. **RPC connection errors** - Check your `.env` file has correct API keys

3. **Verification failures** - Ensure constructor args match exactly, check Etherscan API key

4. **Gas estimation errors** - Add `--gas-limit 3000000` flag if needed

### Debug Mode

Add `--show-progress` and `--verbosity 3` to forge commands for detailed output:

```bash
forge script script/DeployAdapter.s.sol:DeployAdapter --rpc-url $RPC_URL --broadcast --via-ir --show-progress --verbosity 3
```

## Next Steps

Consider fully migrating to Forge by:

1. Moving test files to `test/foundry/` (already mostly done)
2. Using `forge test` instead of `hardhat test`
3. Updating CI/CD to use Forge commands
4. Eventually removing Hardhat dependencies

This preserves maximum compatibility while giving you the benefits of Forge's superior Solidity tooling.
