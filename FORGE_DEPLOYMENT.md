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
-   **`scripts/network-config.ts`** - Network and adapter configuration; reads pools from the two files below
-   **`bulla_registry_export/pools.json`** - Every deployed pool on every chain, and its client. bulla-registry publishes it to the backend, frontend, subgraph and CLI, so it must carry everything they need about a pool (DEV-2937). Validated against `bulla_registry_export/pools.schema.json` by `yarn validate:pools`, which `make test` runs
-   **`scripts/pending-pools.json`** - Pools to deploy next

This eliminates redundant configuration and ensures type safety across all deployment scripts.

### Deploying a pool

You edit `scripts/pending-pools.json`; the deploy writes `bulla_registry_export/pools.json`, the record of every deployed pool. Don't add pools to `pools.json` by hand; only its `clients`, display names and categories are edited directly.

1. Add the pool to `scripts/pending-pools.json`, either by hand or from a past pool with `yarn pool:new` (below).
2. Run `yarn deploy:full` or `scripts/deploy-bullaFactoring.ts`. The deploy refuses a `poolKey` that is already deployed and not pending.
3. After the broadcast, the script moves the entry into `pools.json` with its address, permissions and deploy block. If it replaces a pool with the same network and `poolKey`, it sets `supersededBy` on the old one and gives it the category in the pending entry's `replaces`: `hidden` for a bad deploy nobody should see (the usual case), or `archived` to keep its history on the Archived tab. A redeploy's entry must set `replaces` and a new pool's must not; the deploy refuses otherwise, so nothing picks the old pool's category by default.
4. Commit `pools.json`, `pending-pools.json` and the broadcast. `TestPoolBroadcasts` fails for any V2.1+ pool in `pools.json` with no committed broadcast (POOLDEPLOY-15).

`yarn pool:new --from <network>/<poolKey|address> [--network <network>] [--pool-key <key>] [--asset <address>]` copies a past pool's config into a pending entry. On the same chain it reuses the pool's permissions contracts; on another chain it leaves them out, so the deploy creates new ones, and takes the asset on that chain (from `--asset`, or the one asset `pools.json` lists there with the same symbol). Keeping the source's `poolKey` on the same chain makes the deploy replace that pool; then `--replaces archived|hidden` is required.

**A) A new client.** Add the client under `clients` in `pools.json` (with `logos/<client>.svg|png` if they have a logo). Add a pending entry with a new `poolKey`, by hand or with `pool:new --from` a similar pool and `--pool-key`, then edit the client, names and fees.

**B) A new chain.** Add it to `scripts/networks.ts` (chain id, RPC, explorer key env) and to the `network` enum in `pools.schema.json` (`yarn validate:pools` fails until both match). Add its Bulla contracts to `networkConfigs` in `scripts/network-config.ts`. Then deploy as in A or C with `--network`; the first pool of a version on the chain deploys the adapter and records it in `versionConfigs`.

**C) An existing client on a new pool version.** Once the contracts are released: add the version at the end of `POOL_CONTRACT_VERSIONS` in `scripts/utils/pools.ts` and to the `version` enum in `pools.schema.json`, and set `CURRENT_POOL_VERSION` in `scripts/network-config.ts`. The deploy then records the new version and looks for its contract (`BullaFactoringV2_3`) in the broadcast. The Solidity deploy scripts and the constructor signature in `scripts/utils/verify-forge.ts` change with the contract itself. Then `yarn pool:new --from <network>/<poolKey>` and deploy: the new pool supersedes the old one. A version's adapter is per chain, so the first deploy of a new version on a chain deploys one.

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
