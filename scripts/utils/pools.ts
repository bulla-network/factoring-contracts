// The pool configs, published as bulla_registry_export/pools.json (DEV-2937, POOLDEPLOY-15).
// network-config.ts, the deploy scripts and test/foundry/predeploy/TestPoolBroadcasts.t.sol all read pools from here.
import Ajv from 'ajv';
import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { NETWORK_CHAIN_IDS } from '../networks';

export { NETWORK_CHAIN_IDS };

const ROOT = join(__dirname, '..', '..');
export const POOLS_PATH = join(ROOT, 'bulla_registry_export', 'pools.json');
export const PENDING_POOLS_PATH = join(ROOT, 'scripts', 'pending-pools.json');
export const POOLS_SCHEMA_PATH = join(ROOT, 'bulla_registry_export', 'pools.schema.json');

/**
 * Every pool contract version, oldest first. A new version goes at the end (and in the `version` enum in
 * pools.schema.json; validate-pools checks they match), then bump CURRENT_POOL_VERSION in network-config.ts.
 */
export const POOL_CONTRACT_VERSIONS = ['V0', 'V1', 'V2_1', 'V2_2'] as const;
export type PoolContractVersion = typeof POOL_CONTRACT_VERSIONS[number];

/** True if `version` is `since` or newer */
export function isAtLeast(version: PoolContractVersion, since: PoolContractVersion): boolean {
    return POOL_CONTRACT_VERSIONS.indexOf(version) >= POOL_CONTRACT_VERSIONS.indexOf(since);
}

/** The first version with redeem permissions, and the first with an insurance fee */
const REDEEM_SINCE: PoolContractVersion = 'V2_1';
const INSURANCE_SINCE: PoolContractVersion = 'V2_2';
export type PoolCategory = 'active' | 'archived';

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
    /** redeem is absent on V0 and V1 pools, which have none */
    permissions: { factoring: string; deposit: string; redeem?: string };
    underwriter: string;
    /** insuranceBps is absent before V2.2, which has no insurance fee */
    fees: { protocolBps: number; adminBps: number; targetYieldBps: number; insuranceBps?: number };
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
        // A field is present exactly when the pool's version has it, never null
        const hasInsurance = isAtLeast(p.version, INSURANCE_SINCE);
        if (hasInsurance && p.fees.insuranceBps === undefined) errors.push(`${where(p)}: a ${p.version} pool needs fees.insuranceBps`);
        if (!hasInsurance && p.fees.insuranceBps !== undefined) {
            errors.push(`${where(p)}: a ${p.version} pool has no insurance fee; remove fees.insuranceBps`);
        }
        const hasRedeem = isAtLeast(p.version, REDEEM_SINCE);
        if (hasRedeem && p.permissions.redeem === undefined) errors.push(`${where(p)}: a ${p.version} pool needs permissions.redeem`);
        if (!hasRedeem && p.permissions.redeem !== undefined) {
            errors.push(`${where(p)}: a ${p.version} pool has no redeem permissions; remove permissions.redeem`);
        }
        if (p.supersededBy) {
            const next = file.pools.find(q => q.chainId === p.chainId && same(q.address, p.supersededBy));
            if (!next) errors.push(`${where(p)}: supersededBy ${p.supersededBy} is not a pool on the same chain`);
            else if (same(next.address, p.address)) errors.push(`${where(p)}: supersedes itself`);
            else {
                if (next.poolKey !== p.poolKey) errors.push(`${where(p)}: superseded by ${next.address}, which has another poolKey`);
                if (next.deployBlock <= p.deployBlock) errors.push(`${where(p)}: superseded by ${next.address}, which is not newer`);
            }
        }
    });

    // A poolKey's history is a line: each redeploy replaces the pool before it, so no pool replaces two
    const replaced = new Map<string, Pool>();
    file.pools
        .filter(p => p.supersededBy)
        .forEach(p => {
            const k = `${p.chainId}-${p.supersededBy!.toLowerCase()}`;
            const other = replaced.get(k);
            if (other) {
                errors.push(
                    `${p.network} ${p.supersededBy}: supersedes two pools (${other.address}, ${p.address}); point the older one at the pool that replaced it`,
                );
            }
            replaced.set(k, p);
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

/** The schema's network and version enums must list what the scripts know, so a new chain or version can't miss one */
export function schemaDriftErrors(schema: any = readJson(POOLS_SCHEMA_PATH)): string[] {
    const errors: string[] = [];
    const sameList = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((x, i) => x === b[i]);
    const networks = Object.keys(NETWORK_CHAIN_IDS);
    if (!sameList([...(schema.definitions?.network?.enum ?? [])].sort(), [...networks].sort())) {
        errors.push(`pools.schema.json network enum must be exactly the networks in scripts/networks.ts: ${networks.join(', ')}`);
    }
    if (!sameList(schema.definitions?.pool?.properties?.version?.enum ?? [], POOL_CONTRACT_VERSIONS)) {
        errors.push(`pools.schema.json version enum must be POOL_CONTRACT_VERSIONS, in order: ${POOL_CONTRACT_VERSIONS.join(', ')}`);
    }
    return errors;
}

/** Every problem with pools.json and pending-pools.json, schema first. Empty if both are valid. */
export function validatePoolFiles(pools: unknown = readJson(POOLS_PATH), pending: unknown = readJson(PENDING_POOLS_PATH)): string[] {
    const errors = [
        ...schemaDriftErrors(),
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
 * and poolKey) as superseded and archived, and removes the pending entry. Validates before writing.
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
        previous.category = 'archived';
    }
    pools.pools.push(pool);
    pendingFile.pools = pendingFile.pools.filter(p => !(p.network === pending.network && p.poolKey === pending.poolKey));

    const errors = validatePoolFiles(pools, pendingFile);
    if (errors.length) throw new Error(`Refusing to write an invalid pool config:\n  ${errors.join('\n  ')}`);

    writeJson(POOLS_PATH, pools);
    writeJson(PENDING_POOLS_PATH, pendingFile);
    return pool;
}

/** The pool `ref` names: `<network>/<poolKey>` (its current pool) or `<network>/<address>` (any pool, e.g. one with no poolKey) */
export function findPoolByRef(file: PoolsFile, ref: string): Pool | undefined {
    const [network, key] = ref.split('/');
    if (!network || !key) return undefined;
    if (/^0x[0-9a-fA-F]{40}$/.test(key)) return file.pools.find(p => p.network === network && same(p.address, key));
    return findCurrentPool(file, network, key);
}

/** Assets pools.json already lists on `network`, by lowercase address */
export function knownAssets(file: PoolsFile, network: string): Map<string, Asset> {
    const assets = new Map<string, Asset>();
    file.pools.filter(p => p.network === network).forEach(p => assets.set(p.asset.address.toLowerCase(), p.asset));
    return assets;
}

/**
 * A pending-pools.json entry that redeploys `source`'s config as `poolKey` on `network` (pool:new --from).
 * Same chain: reuses its permissions contracts. Another chain: leaves them out, so the deploy creates new ones,
 * and takes `asset`, the asset on that chain. The insurance fee carries over only if the source has one.
 */
export function pendingFromPool(source: Pool, target: { network: string; poolKey: string; asset?: Asset }): PendingPool {
    const sameChain = source.network === target.network;
    if (!sameChain && !target.asset) throw new Error(`${source.network} → ${target.network}: name the asset on ${target.network}`);
    const { protocolBps, adminBps, targetYieldBps, insuranceBps } = source.fees;
    return {
        network: target.network,
        poolKey: target.poolKey,
        client: source.client,
        displayName: source.displayName,
        category: 'active',
        shareToken: { symbol: source.shareToken.symbol, name: source.shareToken.name },
        asset: target.asset ?? source.asset,
        insured: source.insured,
        enforceKyc: source.enforceKyc,
        ...(sameChain && { permissions: { ...source.permissions } }),
        underwriter: source.underwriter,
        fees: { protocolBps, adminBps, targetYieldBps, ...(insuranceBps !== undefined && { insuranceBps }) },
    };
}

/** Adds `entry` to pending-pools.json after validating both files with it */
export function addPendingPool(entry: PendingPool): void {
    const pools = loadPools();
    const pending = loadPendingPools();
    pending.pools.push(entry);
    const errors = validatePoolFiles(pools, pending);
    if (errors.length) throw new Error(`Refusing to write an invalid pending-pools.json:\n  ${errors.join('\n  ')}`);
    writeJson(PENDING_POOLS_PATH, pending);
}
