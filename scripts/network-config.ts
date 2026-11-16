// Shared network and pool configurations for deployment and permissions scripts.
// Networks and adapters live here. Pools live in bulla_registry_export/pools.json (deployed, published through
// bulla-registry) and scripts/pending-pools.json (to deploy next); see scripts/utils/pools.ts.

import { getChainId, getEtherscanApiKey, getRpcUrl, NetworkName } from './networks';
import {
    findCurrentPool,
    findPendingPool,
    loadValidatedPools,
    PendingPool,
    Pool,
    POOL_CONTRACT_VERSIONS,
    PoolContractVersion,
} from './utils/pools';

// Chain ids, RPCs and explorer keys live in networks.ts
export { getChainId, getEtherscanApiKey, getRpcUrl };

// ============================================================================
// Global Constants
// ============================================================================

/** Default protocol fee in basis points (30 bps = 0.30%) */
export const DEFAULT_PROTOCOL_FEE_BPS = 30;

// ============================================================================
// Types
// ============================================================================

/** A pool's poolKey in pools.json, e.g. 'tcs' or 'tcs-wyoming' */
export type PoolName = string;

/** The versions the scripts deploy, from V2.1 on, named the way the CLI and versionConfigs take them: V2_2 is 'v2.2' */
type ScriptVersion<V> = V extends `V${infer Major}_${infer Minor}` ? `v${Major}.${Minor}` : never;
export type PoolVersion = ScriptVersion<PoolContractVersion>;

/** pools.json's version for a script version: 'v2.2' is V2_2 */
export function toContractVersion(version: PoolVersion): PoolContractVersion {
    return `V${version.slice(1).replace('.', '_')}` as PoolContractVersion;
}

const allPoolVersions = POOL_CONTRACT_VERSIONS.filter(v => v.includes('_')).map(
    v => `v${v.slice(1).replace('_', '.')}` as PoolVersion,
);

/** The pool contract a deploy of `version` creates, as named in the broadcast: BullaFactoringV2_2 */
export function poolContractName(version: PoolVersion = CURRENT_POOL_VERSION): string {
    return `BullaFactoring${toContractVersion(version)}`;
}

/** The pool contract version this repo builds (contracts/BullaFactoring.sol), so the version every deploy from here uses */
export const CURRENT_POOL_VERSION: PoolVersion = 'v2.2';

/** Network-specific configuration shared by every pool on the chain, whatever its version (not tied to any pool) */
export type NetworkConfig = {
    bullaClaim: string;
    bullaDao: string;
    bullaFrendLendAddress: string;
    bullaInvoiceAddress: string;
    bullaFactoringFactoryAddress?: string;
    sumsubKycIssuerAddress?: string;
    agreementSignatureRepoAddress?: string;
    sanctionsListAddress?: string;
    bullaKycGateAddress?: string;
    complianceDepositPermissionsAddress?: string;
};

/**
 * Configuration shared by every pool of one contract version on one chain (POOLDEPLOY R5).
 * Each pool version is compiled against its own adapter interface, so an adapter belongs to one version.
 */
export type VersionConfig = {
    invoiceProviderAdapterAddress?: string;
};

/** A pool's fees, from its pools.json or pending-pools.json entry */
export type PoolConfig = {
    protocolFeeBps: number;
    adminFeeBps: number;
    targetYieldBps: number;
    insuranceFeeBps?: number;
};

/** A pool on one network, from its pools.json entry or, if it is about to be deployed, its pending-pools.json entry */
export type DeployedPoolConfig = {
    underlyingAsset: string;
    poolDisplayName: string;
    poolTokenName: string;
    poolTokenSymbol: string;
    underwriter: string;
    factoringPermissionsAddress?: string;
    depositPermissionsAddress?: string;
    redeemPermissionsAddress?: string;
    /** Unset while the pool is pending */
    bullaFactoringAddress?: string;
};

/** Combined config returned by getConfig() */
export type FullConfig = NetworkConfig &
    PoolConfig &
    DeployedPoolConfig & {
        /** From the chain and version config, never from another version's */
        BullaClaimInvoiceProviderAdapterAddress?: string;
        poolName: PoolName;
        poolVersion: PoolVersion;
        network: string;
        /** Set when the pool is in pending-pools.json, i.e. the next deploy creates it */
        pending?: PendingPool;
    };

// ============================================================================
// Network Configurations (Network-only, no pool info)
// ============================================================================

/** The networks the scripts deploy to. A network here must be in networks.ts too */
export const networkConfigs: Partial<Record<NetworkName, NetworkConfig>> = {
    sepolia: {
        bullaClaim: '0x0d9EF9d436fF341E500360a6B5E5750aB85BCCB6',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x4d6A66D32CF34270e4cc9C9F201CA4dB650Be3f2',
        bullaInvoiceAddress: '0xa2c4B7239A0d179A923751cC75277fe139AB092F',
        sumsubKycIssuerAddress: '0x4f51c54d5a335c4e42c974d0709ef034a5864858',
        agreementSignatureRepoAddress: '0xead7c69c5216fdf189c4bed56185dbbdb456812c',
        bullaKycGateAddress: '0xe8681068fa56b8e1423fabb904e1413b2fff36aa',
        complianceDepositPermissionsAddress: '0x62919a63ad1e3176c5b178a072ff2b04cd8a748a',
        // Chainalysis does not deploy on Sepolia — deploy a mock and set the address here
        sanctionsListAddress: '0x1743972c13e24da42330e8768ac3e18b5cfe0ae7',
    },
    polygon: {
        bullaClaim: '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x0000000000000000000000000000000000000000',
        bullaInvoiceAddress: '0x0000000000000000000000000000000000000000',
        sanctionsListAddress: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb', // Chainalysis OFAC oracle
    },
    mainnet: {
        bullaClaim: '0x10a55a4dbd24fa188eed98a2adae2ebff0ef1219',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x1097b7ecf0721aaffff147cf7bec154422896317',
        bullaInvoiceAddress: '0xfe2631bcb3e622750b6fbb605a416173ffa3a770',
        sanctionsListAddress: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb', // Chainalysis OFAC oracle
    },
    base: {
        bullaClaim: '0x8D59E594a3e4D0647C15887Cde5ECBfBE583b441',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x777A7966464a4E5684FE95025aDb2AD56bdaE77B',
        bullaInvoiceAddress: '0x1E1d535a41515D3D2c29C1524C825236D67733E1',
        sanctionsListAddress: '0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B', // Chainalysis OFAC oracle (Base-specific)
    },
    arbitrum: {
        bullaClaim: '0xb58f4f651553d51d95c69f59364a9ee1ca554b7e',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x1a34dfd1ee17130228452f3d9cdda5908865d22d',
        bullaInvoiceAddress: '0x74c62f475464a03a462578d65629240b34221c1b',
        sanctionsListAddress: '0x40C57923924B5c5c5455c48D93317139ADDaC8fb', // Chainalysis OFAC oracle
    },
};

// ============================================================================
// Version Configurations (Network + pool contract version)
// ============================================================================

/**
 * Per chain and pool contract version. A new pool version gets a new entry, so a pool never
 * picks up an older version's adapter. If the entry has no adapter, the pool deploy deploys one
 * and writes it here, and later pools of that version on that chain reuse it.
 */
// The adapters below predate v2.2 (none has getImpairTarget), so a v2.2 pool must not use them.
export const versionConfigs: Partial<Record<NetworkName, Partial<Record<PoolVersion, VersionConfig>>>> = {
    sepolia: {
        'v2.1': { invoiceProviderAdapterAddress: '0x2c6c46d6b1b5121b0072c8b9f4eb836fe1252f78' },
        'v2.2': { invoiceProviderAdapterAddress: '0x63fadf50d85135baf709c9dc65553f14029fd89b' },
    },
    polygon: {
        'v2.1': { invoiceProviderAdapterAddress: '0xB5B31E95f0C732450Bc869A6467A9941C8565b10' },
    },
    mainnet: {
        'v2.1': { invoiceProviderAdapterAddress: '0x74c62f475464a03a462578d65629240b34221c1b' },
    },
    base: {
        'v2.1': { invoiceProviderAdapterAddress: '0x4d4f494f4e6232d2be0a055359eb29edb17ae0ca' },
    },
    arbitrum: {
        // DEV-2824: synced from release/v2.1 (#230); 0x2C6c46d6... was a Sepolia copy-paste with no code on Arbitrum
        'v2.1': { invoiceProviderAdapterAddress: '0xdb44baa27F4C4c57CdbdAC684D39900A0C54bc89' },
        'v2.2': { invoiceProviderAdapterAddress: '0x7b3776dccdb3965ab9d414f5c9db5a07177ea449' },
    },
};

// ============================================================================
// Pools (bulla_registry_export/pools.json and scripts/pending-pools.json)
// ============================================================================

function fromPool(pool: Pool): PoolConfig & DeployedPoolConfig {
    return {
        protocolFeeBps: pool.fees.protocolBps,
        adminFeeBps: pool.fees.adminBps,
        targetYieldBps: pool.fees.targetYieldBps,
        ...(pool.fees.insuranceBps !== undefined && { insuranceFeeBps: pool.fees.insuranceBps }),
        underlyingAsset: pool.asset.address,
        poolDisplayName: pool.displayName,
        poolTokenName: pool.shareToken.name,
        poolTokenSymbol: pool.shareToken.symbol,
        underwriter: pool.underwriter,
        factoringPermissionsAddress: pool.permissions.factoring,
        depositPermissionsAddress: pool.permissions.deposit,
        redeemPermissionsAddress: pool.permissions.redeem,
        bullaFactoringAddress: pool.address,
    };
}

function fromPendingPool(pool: PendingPool): PoolConfig & DeployedPoolConfig {
    return {
        protocolFeeBps: pool.fees.protocolBps,
        adminFeeBps: pool.fees.adminBps,
        targetYieldBps: pool.fees.targetYieldBps,
        ...(pool.fees.insuranceBps !== undefined && { insuranceFeeBps: pool.fees.insuranceBps }),
        underlyingAsset: pool.asset.address,
        poolDisplayName: pool.displayName,
        poolTokenName: pool.shareToken.name,
        poolTokenSymbol: pool.shareToken.symbol,
        underwriter: pool.underwriter,
        factoringPermissionsAddress: pool.permissions?.factoring,
        depositPermissionsAddress: pool.permissions?.deposit,
        redeemPermissionsAddress: pool.permissions?.redeem,
    };
}

/**
 * A pool's config: its pending-pools.json entry if it has one (the deploy is about to create it), else the pool
 * pools.json currently lists for that network and poolKey. Undefined if neither has it.
 */
function getDeploymentConfig(network: string, pool: PoolName): (PoolConfig & DeployedPoolConfig & { pending?: PendingPool }) | undefined {
    const { pools, pending } = loadValidatedPools();
    const pendingPool = findPendingPool(pending, network, pool);
    if (pendingPool) return { ...fromPendingPool(pendingPool), pending: pendingPool };
    const current = findCurrentPool(pools, network, pool);
    return current && fromPool(current);
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Get full configuration for a network and pool combination
 * @param network - Network name, a key of networkConfigs
 * @param pool - The pool's poolKey in pools.json or pending-pools.json. Defaults to 'tcs'
 * @param version - Pool contract version. Defaults to the version this repo builds
 * @throws Error if network is unsupported or neither pool file has the pool on the network
 */
export function getConfig(network: string, pool: PoolName = 'tcs', version: PoolVersion = CURRENT_POOL_VERSION): FullConfig {
    if (!network) {
        throw new Error('Network parameter is required');
    }

    const networkConfig = networkConfigs[network as NetworkName];
    if (!networkConfig) {
        throw new Error(`Unsupported network: ${network}. Available: ${Object.keys(networkConfigs).join(', ')}`);
    }

    const deployedPoolConfig = getDeploymentConfig(network, pool);
    if (!deployedPoolConfig) {
        throw new Error(
            `Pool '${pool}' is not on network '${network}'. Available: ${getAvailablePools(network).join(', ') || 'none'}. ` +
                `To deploy a new pool, add it to scripts/pending-pools.json`,
        );
    }

    return {
        ...networkConfig,
        ...deployedPoolConfig,
        BullaClaimInvoiceProviderAdapterAddress: getVersionConfig(network, version).invoiceProviderAdapterAddress,
        poolName: pool,
        poolVersion: version,
        network: network,
    };
}

/**
 * @deprecated Use getConfig(network, pool) instead
 * Legacy function for backwards compatibility
 */
export function getNetworkConfig(network: string): FullConfig {
    return getConfig(network, 'tcs');
}

// ============================================================================
// Utility Functions
// ============================================================================

/** Every poolKey on the network: pending pools, and pools pools.json currently lists with a poolKey */
export function getAvailablePools(network: string): PoolName[] {
    const { pools, pending } = loadValidatedPools();
    const keys = [
        ...pending.pools.filter(p => p.network === network).map(p => p.poolKey),
        ...pools.pools.filter(p => p.network === network && p.poolKey && !p.supersededBy).map(p => p.poolKey as string),
    ];
    return [...new Set(keys)];
}

export function getAvailableNetworks(): string[] {
    return Object.keys(networkConfigs);
}

export function getNetworkOnlyConfig(network: string): NetworkConfig {
    const config = networkConfigs[network as NetworkName];
    if (!config) {
        throw new Error(`Unsupported network: ${network}. Available: ${Object.keys(networkConfigs).join(', ')}`);
    }
    return config;
}

/** Config for one chain and pool contract version. Empty if that version has nothing on the chain yet */
export function getVersionConfig(network: string, version: PoolVersion = CURRENT_POOL_VERSION): VersionConfig {
    if (!networkConfigs[network as NetworkName]) {
        throw new Error(`Unsupported network: ${network}. Available: ${Object.keys(networkConfigs).join(', ')}`);
    }
    if (!allPoolVersions.includes(version)) {
        throw new Error(`Unsupported pool version: ${version}. Available: ${allPoolVersions.join(', ')}`);
    }
    return versionConfigs[network as NetworkName]?.[version] ?? {};
}

export function getDeployedPoolConfig(network: string, pool: PoolName): DeployedPoolConfig | undefined {
    return getDeploymentConfig(network, pool);
}

/** True if pools.json lists a current pool for the network and poolKey */
export function isPoolDeployed(network: string, pool: PoolName): boolean {
    return findCurrentPool(loadValidatedPools().pools, network, pool) !== undefined;
}
