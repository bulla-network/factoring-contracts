// The pool configs, published as bulla_registry_export/pools.json (DEV-2937, POOLDEPLOY-15).
// network-config.ts, the deploy scripts and test/foundry/predeploy/TestPoolBroadcasts.t.sol all read pools from here.
import Ajv from 'ajv';
import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

const ROOT = join(__dirname, '..', '..');
export const POOLS_PATH = join(ROOT, 'bulla_registry_export', 'pools.json');
export const PENDING_POOLS_PATH = join(ROOT, 'scripts', 'pending-pools.json');
export const POOLS_SCHEMA_PATH = join(ROOT, 'bulla_registry_export', 'pools.schema.json');

/** Chain id of every network a pool can be on. Must match the `network` enum in pools.schema.json. */
export const NETWORK_CHAIN_IDS: Record<string, number> = {
    mainnet: 1,
    sepolia: 11155111,
    polygon: 137,
    base: 8453,
    arbitrum: 42161,
    redbelly: 151,
    xdc: 50,
};

export type PoolContractVersion = 'V0' | 'V1' | 'V2' | 'V2_1' | 'V2_2';
export type PoolCategory = 'active' | 'test' | 'archived' | 'hidden';

export type Client = {
    displayName: string;
    website?: string;
    logo?: string;
};

export type Asset = {
    address: string;
    symbol: string;
    name: string;
    decimals: number;
    kind: 'stable' | 'volatile';
};

export type Pool = {
    chainId: number;
    network: string;
    address: string;
    version: PoolContractVersion;
    client: string;
    poolKey?: string;
    displayName: string;
    category: PoolCategory;
    supersededBy?: string;
    shareToken: { symbol: string; name: string; decimals: number };
    asset: Asset;
    insured: boolean;
    enforceKyc: boolean;
    permissions: { factoring: string; deposit: string; redeem: string | null };
    underwriter: string;
    fees: { protocolBps: number; adminBps: number; targetYieldBps: number; insuranceBps: number | null };
    deployBlock: number;
};

export type PoolsFile = {
    $schema?: string;
    clients: Record<string, Client>;
    pools: Pool[];
};

/** A pool to deploy: everything a Pool has except what only exists once it's deployed */
export type PendingPool = {
    network: string;
    poolKey: string;
    client: string;
    displayName: string;
    category: PoolCategory;
    shareToken: { symbol: string; name: string };
    asset: Asset;
    insured: boolean;
    enforceKyc: boolean;
    permissions?: { factoring?: string; deposit?: string; redeem?: string };
    underwriter: string;
    fees: { protocolBps: number; adminBps: number; targetYieldBps: number; insuranceBps?: number };
};

export type PendingPoolsFile = {
    $schema?: string;
    pools: PendingPool[];
};

const same = (a: string | undefined | null, b: string | undefined | null) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

function readJson<T>(path: string): T {
    return JSON.parse(readFileSync(path, 'utf-8')) as T;
}

function writeJson(path: string, value: unknown): void {
    writeFileSync(path, JSON.stringify(value, null, 4) + '\n', 'utf-8');
}

function schemaErrors(data: unknown, ref: string): string[] {
    const ajv = new Ajv({ allErrors: true });
    ajv.addSchema(readJson(POOLS_SCHEMA_PATH), 'pools');
    const validate = ajv.getSchema(`pools${ref}`);
    if (!validate) throw new Error(`pools.schema.json has no ${ref}`);
    if (validate(data)) return [];
    return (validate.errors ?? []).map(e => `${e.dataPath || '/'} ${e.message}`);
}

/** The rules JSON Schema can't express. Returns one message per broken rule. */
export function poolsRuleErrors(file: PoolsFile): string[] {
    const errors: string[] = [];
    const where = (p: Pool) => `${p.network} ${p.address}`;

    file.pools.forEach(p => {
        if (NETWORK_CHAIN_IDS[p.network] !== p.chainId) {
            errors.push(`${where(p)}: chainId ${p.chainId} is not ${p.network}'s (${NETWORK_CHAIN_IDS[p.network]})`);
        }
        if (!file.clients[p.client]) errors.push(`${where(p)}: unknown client '${p.client}'`);
        if (p.version === 'V2_2' && p.fees.insuranceBps === null) errors.push(`${where(p)}: a V2_2 pool has an insurance fee`);
        if (['V0', 'V1'].includes(p.version) && p.permissions.redeem !== null) {
            errors.push(`${where(p)}: a ${p.version} pool has no redeem permissions; set redeem to null`);
        }
        if (p.supersededBy) {
            const next = file.pools.find(q => q.chainId === p.chainId && same(q.address, p.supersededBy));
            if (!next) errors.push(`${where(p)}: supersededBy ${p.supersededBy} is not a pool on the same chain`);
            else if (same(next.address, p.address)) errors.push(`${where(p)}: supersedes itself`);
        }
    });

    const seen = new Map<string, Pool>();
    file.pools.forEach(p => {
        const k = `${p.chainId}-${p.address.toLowerCase()}`;
        if (seen.has(k)) errors.push(`${where(p)}: listed twice`);
        seen.set(k, p);
    });

    const current = new Map<string, Pool>();
    file.pools
        .filter(p => p.poolKey && !p.supersededBy)
        .forEach(p => {
            const k = `${p.chainId}-${p.poolKey}`;
            const other = current.get(k);
            if (other) {
                errors.push(
                    `${p.network} ${p.poolKey}: two current pools (${other.address}, ${p.address}); set supersededBy on the older one`,
                );
            }
            current.set(k, p);
        });

    return errors;
}

export function pendingRuleErrors(pending: PendingPoolsFile, pools: PoolsFile): string[] {
    const errors: string[] = [];
    const seen = new Set<string>();
    pending.pools.forEach(p => {
        const k = `${p.network}-${p.poolKey}`;
        if (seen.has(k)) errors.push(`pending ${p.network} ${p.poolKey}: listed twice`);
        seen.add(k);
        if (!pools.clients[p.client]) errors.push(`pending ${p.network} ${p.poolKey}: unknown client '${p.client}' (add it to pools.json clients)`);
    });
    return errors;
}

/** Every problem with pools.json and pending-pools.json, schema first. Empty if both are valid. */
export function validatePoolFiles(pools: unknown = readJson(POOLS_PATH), pending: unknown = readJson(PENDING_POOLS_PATH)): string[] {
    const errors = [
        ...schemaErrors(pools, '#').map(e => `pools.json ${e}`),
        ...schemaErrors(pending, '#/definitions/pendingPoolsFile').map(e => `pending-pools.json ${e}`),
    ];
    if (errors.length) return errors;
    return [...poolsRuleErrors(pools as PoolsFile), ...pendingRuleErrors(pending as PendingPoolsFile, pools as PoolsFile)];
}

export function loadPools(): PoolsFile {
    return readJson<PoolsFile>(POOLS_PATH);
}

export function loadPendingPools(): PendingPoolsFile {
    return readJson<PendingPoolsFile>(PENDING_POOLS_PATH);
}

/** Loads both files and throws if either is invalid, so no script runs on a bad config */
export function loadValidatedPools(): { pools: PoolsFile; pending: PendingPoolsFile } {
    const pools = loadPools();
    const pending = loadPendingPools();
    const errors = validatePoolFiles(pools, pending);
    if (errors.length) throw new Error(`Invalid pool config:\n  ${errors.join('\n  ')}`);
    return { pools, pending };
}

/** The pool a network and poolKey currently point at (the one no redeploy superseded) */
export function findCurrentPool(file: PoolsFile, network: string, poolKey: string): Pool | undefined {
    return file.pools.find(p => p.network === network && p.poolKey === poolKey && !p.supersededBy);
}

export function findPendingPool(file: PendingPoolsFile, network: string, poolKey: string): PendingPool | undefined {
    return file.pools.find(p => p.network === network && p.poolKey === poolKey);
}

/**
 * Records a pool the deploy script just created: adds it to pools.json, marks the pool it replaces (same network
 * and poolKey) as superseded and hidden, and removes the pending entry. Validates before writing.
 */
export function recordDeployedPool(
    pending: PendingPool,
    deployed: {
        address: string;
        version: PoolContractVersion;
        deployBlock: number;
        permissions: { factoring: string; deposit: string; redeem: string };
        insuranceBps: number;
    },
): Pool {
    const pools = loadPools();
    const pendingFile = loadPendingPools();
    const chainId = NETWORK_CHAIN_IDS[pending.network];

    const pool: Pool = {
        chainId,
        network: pending.network,
        address: deployed.address,
        version: deployed.version,
        client: pending.client,
        poolKey: pending.poolKey,
        displayName: pending.displayName,
        category: pending.category,
        shareToken: { ...pending.shareToken, decimals: pending.asset.decimals },
        asset: pending.asset,
        insured: pending.insured,
        enforceKyc: pending.enforceKyc,
        permissions: deployed.permissions,
        underwriter: pending.underwriter,
        fees: {
            protocolBps: pending.fees.protocolBps,
            adminBps: pending.fees.adminBps,
            targetYieldBps: pending.fees.targetYieldBps,
            insuranceBps: deployed.insuranceBps,
        },
        deployBlock: deployed.deployBlock,
    };

    const previous = findCurrentPool(pools, pending.network, pending.poolKey);
    if (previous) {
        previous.supersededBy = deployed.address;
        previous.category = 'hidden';
    }
    pools.pools.push(pool);
    pendingFile.pools = pendingFile.pools.filter(p => !(p.network === pending.network && p.poolKey === pending.poolKey));

    const errors = validatePoolFiles(pools, pendingFile);
    if (errors.length) throw new Error(`Refusing to write an invalid pool config:\n  ${errors.join('\n  ')}`);

    writeJson(POOLS_PATH, pools);
    writeJson(PENDING_POOLS_PATH, pendingFile);
    return pool;
}
