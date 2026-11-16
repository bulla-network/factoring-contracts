// Every network a pool can be on, in one place. Adding a chain starts here; see FORGE_DEPLOYMENT.md, "Deploying a pool".
// The `network` enum in bulla_registry_export/pools.schema.json must list the same names; validate-pools checks it.

export type Network = {
    chainId: number;
    /** Unset on networks the scripts can't deploy to (pools there were deployed by hand) */
    rpcUrl?: () => string;
    /** The env var holding the block explorer API key. Unset: contracts on this network can't be verified from here */
    explorerApiKeyEnv?: string;
};

/** Keeps each network's literal name in NetworkName while checking it is a Network (TS 4.7 has no `satisfies`) */
const defineNetworks = <T extends Record<string, Network>>(networks: T): T => networks;

const ANKR_KEY = 'ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc';

export const NETWORKS = defineNetworks({
    mainnet: {
        chainId: 1,
        rpcUrl: () => `https://go.getblock.io/${process.env.MAINNET_GETBLOCK_API_KEY}`,
        explorerApiKeyEnv: 'ETHERSCAN_API_KEY',
    },
    sepolia: {
        chainId: 11155111,
        rpcUrl: () =>
            process.env.INFURA_API_KEY
                ? `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`
                : `https://rpc.ankr.com/eth_sepolia/${ANKR_KEY}`,
        explorerApiKeyEnv: 'ETHERSCAN_API_KEY',
    },
    polygon: {
        chainId: 137,
        rpcUrl: () => `https://rpc.ankr.com/polygon/${ANKR_KEY}`,
        explorerApiKeyEnv: 'POLYGONSCAN_API_KEY',
    },
    base: {
        chainId: 8453,
        rpcUrl: () => `https://rpc.ankr.com/base/${ANKR_KEY}`,
        explorerApiKeyEnv: 'ETHERSCAN_API_KEY',
    },
    arbitrum: {
        chainId: 42161,
        rpcUrl: () => 'https://arb1.arbitrum.io/rpc',
        explorerApiKeyEnv: 'ARBISCAN_API_KEY',
    },
    redbelly: { chainId: 151 },
    xdc: { chainId: 50 },
});

export type NetworkName = keyof typeof NETWORKS;

const names = Object.keys(NETWORKS) as NetworkName[];
const byName = (name: NetworkName): Network => NETWORKS[name];

/** Chain id of every network a pool can be on */
export const NETWORK_CHAIN_IDS: Record<string, number> = names.reduce(
    (ids, name) => ({ ...ids, [name]: byName(name).chainId }),
    {} as Record<string, number>,
);

export function isNetworkName(name: string): name is NetworkName {
    return name in NETWORKS;
}

function network(name: string): Network {
    if (!isNetworkName(name)) throw new Error(`Unknown network: ${name}. Known: ${names.join(', ')}`);
    return byName(name);
}

export function getChainId(name: string): number {
    return network(name).chainId;
}

export function getRpcUrl(name: string): string {
    const { rpcUrl } = network(name);
    if (!rpcUrl) throw new Error(`No RPC configured for network: ${name}`);
    return rpcUrl();
}

export function getEtherscanApiKey(name: string): string {
    const { explorerApiKeyEnv } = network(name);
    if (!explorerApiKeyEnv) throw new Error(`No block explorer API key configured for network: ${name}`);
    return process.env[explorerApiKeyEnv]!;
}

/** The network with this chain id, if the scripts can verify contracts on it */
export function getVerifiableNetworkByChainId(chainId: number | string): NetworkName | undefined {
    return names.find(name => byName(name).chainId === Number(chainId) && byName(name).explorerApiKeyEnv);
}
