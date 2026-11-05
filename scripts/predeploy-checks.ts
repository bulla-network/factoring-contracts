import { spawn } from 'child_process';
import { getConfig, getRpcUrl, PoolName } from './network-config';
import { buildFactoringEnv } from './utils/factoring-env';
import { getNetworkAndPoolInteractive, promptInput } from './utils/interactive-prompt';

// Spec: bulla-specs deploy-pool.md (POOLDEPLOY)

const FORK_SMOKE_TEST = 'test/foundry/predeploy/fork/TestPreDeployFork.t.sol';

/**
 * Env for PreDeployChecks.s.sol and the fork smoke test: the deploy config plus the POOLDEPLOY-06 inputs.
 */
export function buildPreDeployEnv(network: string, pool: PoolName): NodeJS.ProcessEnv {
    const config = getConfig(network, pool);
    const env: NodeJS.ProcessEnv = {
        ...process.env,
        ...buildFactoringEnv(config, network),
        SANCTIONS_LIST_ADDRESS: config.sanctionsListAddress || '',
        BULLA_KYC_GATE_ADDRESS: config.bullaKycGateAddress || '',
        COMPLIANCE_DEPOSIT_PERMISSIONS_ADDRESS: config.complianceDepositPermissionsAddress || '',
    };
    // Never hand deploy keys to the checks
    delete env.PRIVATE_KEY;
    delete env.DEPLOY_PK;
    return env;
}

function runForge(args: string[], env: NodeJS.ProcessEnv, label: string): Promise<void> {
    return new Promise((resolve, reject) => {
        const proc = spawn('forge', args, { env, stdio: 'inherit', cwd: process.cwd() });
        proc.on('close', code => (code === 0 ? resolve() : reject(new Error(`${label} failed (exit code ${code})`))));
        proc.on('error', error => {
            if ((error as any).code === 'ENOENT') {
                reject(new Error('Forge not found. Make sure Foundry is installed and in your PATH.'));
            } else {
                reject(error);
            }
        });
    });
}

/**
 * Runs POOLDEPLOY-01..POOLDEPLOY-10 (read-only against the target chain) then POOLDEPLOY-11 to POOLDEPLOY-14 (fork smoke test).
 * Rejects if any check fails; callers must not broadcast in that case.
 */
export async function runPreDeployChecks(network: string, pool: PoolName): Promise<void> {
    const rpcUrl = getRpcUrl(network);
    const env = buildPreDeployEnv(network, pool);

    console.log(`🧪 Running pre-deployment checks for ${network}/${pool} (POOLDEPLOY-01..POOLDEPLOY-10)...\n`);
    // No --broadcast and no private key: simulation only
    await runForge(['script', 'script/PreDeployChecks.s.sol:PreDeployChecks', '--rpc-url', rpcUrl, '--via-ir'], env, 'Pre-deployment checks');

    console.log(`\n🧪 Running fork smoke test for ${network}/${pool} (POOLDEPLOY-11 to POOLDEPLOY-14)...\n`);
    await runForge(
        ['test', '--via-ir', '--match-path', FORK_SMOKE_TEST, '--fork-url', rpcUrl, '-vv'],
        { ...env, FOUNDRY_PROFILE: 'test', PREDEPLOY_FORK: 'true' },
        'Fork smoke test',
    );

    // POOLDEPLOY-09 warning needs explicit confirmation
    if (!env.INSURER_ADDRESS) {
        const answer = await promptInput('⚠️  [POOLDEPLOY-09] INSURER_ADDRESS is not set, so the insurer will be the deployer. Continue? (y/N)');
        if (answer.toLowerCase() !== 'y') {
            throw new Error('Aborted: insurer not confirmed (POOLDEPLOY-09)');
        }
    }

    console.log('\n✅ Pre-deployment checks passed\n');
}

async function preDeployChecksLauncher(): Promise<void> {
    try {
        const { network, pool } = await getNetworkAndPoolInteractive();
        await runPreDeployChecks(network, pool);
    } catch (error: any) {
        console.error('❌', error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    preDeployChecksLauncher();
}
