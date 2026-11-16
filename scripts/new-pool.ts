// Starts a pool deploy from a past pool's config: writes a scripts/pending-pools.json entry to review, then deploy.
//
//   yarn pool:new --from <network>/<poolKey|address> [--network <network>] [--pool-key <key>] [--asset <address>]
//
//   --from      The pool to copy: a network's current pool for a poolKey (sepolia/ola), or any pool by address
//   --network   Where to deploy. Default: the source's network. On another chain the permissions are left out
//               (the deploy creates new ones) and --asset is needed unless that chain has one asset with the same symbol
//   --pool-key  The new pool's key. Default: the source's, which makes the deploy replace (supersede) that pool
//   --asset     The asset's address on --network. Its symbol, name and decimals come from pools.json, else the chain
import { Contract, providers, utils } from 'ethers';
import { getAvailableNetworks, getRpcUrl } from './network-config';
import { addPendingPool, Asset, findPoolByRef, knownAssets, loadValidatedPools, pendingFromPool, PoolsFile } from './utils/pools';

function parseArgs(argv: string[]): Record<string, string> {
    const args: Record<string, string> = {};
    for (let i = 0; i < argv.length; i += 2) {
        const flag = argv[i];
        if (!flag.startsWith('--') || argv[i + 1] === undefined) throw new Error(`Expected --flag value, got '${flag}'`);
        args[flag.slice(2)] = argv[i + 1];
    }
    return args;
}

async function readAsset(network: string, address: string, kind: Asset['kind']): Promise<Asset> {
    const erc20 = new Contract(
        address,
        ['function symbol() view returns (string)', 'function name() view returns (string)', 'function decimals() view returns (uint8)'],
        new providers.JsonRpcProvider(getRpcUrl(network)),
    );
    const [symbol, name, decimals] = await Promise.all([erc20.symbol(), erc20.name(), erc20.decimals()]);
    return { address: utils.getAddress(address), symbol, name, decimals, kind };
}

/** The asset on `network` for a pool whose asset elsewhere is `like` */
async function resolveAsset(pools: PoolsFile, network: string, like: Asset, address?: string): Promise<Asset> {
    const known = knownAssets(pools, network);
    if (address) return known.get(address.toLowerCase()) ?? (await readAsset(network, address, like.kind));
    const matches = Array.from(known.values()).filter(a => a.symbol === like.symbol);
    if (matches.length === 1) return matches[0];
    throw new Error(`No single ${like.symbol} on ${network} in pools.json (${matches.length} found); pass --asset <address on ${network}>`);
}

async function main(): Promise<void> {
    const args = parseArgs(process.argv.slice(2));
    if (!args.from) throw new Error('--from <network>/<poolKey|address> is required');

    const { pools } = loadValidatedPools();
    const source = findPoolByRef(pools, args.from);
    if (!source) throw new Error(`No pool ${args.from} in bulla_registry_export/pools.json`);

    const network = args.network ?? source.network;
    if (!getAvailableNetworks().includes(network)) {
        throw new Error(`The scripts can't deploy to ${network}. Available: ${getAvailableNetworks().join(', ')}`);
    }
    const poolKey = args['pool-key'] ?? source.poolKey;
    if (!poolKey) throw new Error(`${args.from} has no poolKey; pass --pool-key`);

    const asset = network === source.network && !args.asset ? undefined : await resolveAsset(pools, network, source.asset, args.asset);
    const entry = pendingFromPool(source, { network, poolKey, asset });
    addPendingPool(entry);

    console.log(`✅ Added ${network}/${poolKey} to scripts/pending-pools.json, from ${source.network} ${source.address}:\n`);
    console.log(JSON.stringify(entry, null, 4));
    console.log('\nReview it (display name, share token, fees), then run yarn deploy:full.');
    if (network !== source.network) console.log('Permissions are left out, so the deploy creates new ones on this chain.');
    if (entry.fees.insuranceBps === undefined) console.log('No insurance fee given: the deploy uses its default (100 bps).');
}

main().catch(error => {
    console.error(`❌ ${(error as Error).message}`);
    process.exit(1);
});
