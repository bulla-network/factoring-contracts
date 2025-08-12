import { ChildProcess, spawn } from 'child_process';
import * as readline from 'readline';

// Function to prompt for private key
export function promptForPrivateKey(): Promise<string> {
    return new Promise(resolve => {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });

        console.log('⚠️  WARNING: Your private key input will be visible on screen.');
        console.log('🔒 Make sure no one is watching your screen!\n');

        rl.question('Enter your private key: ', privateKey => {
            rl.close();
            // Clear the screen to hide the private key
            console.clear();
            resolve(privateKey.trim());
        });
    });
}

// Function to validate private key format
export function validatePrivateKey(privateKey: string): string {
    if (!privateKey) {
        throw new Error('Private key is required');
    }

    if (!privateKey.match(/^(0x)?[a-fA-F0-9]{64}$/)) {
        throw new Error('Invalid private key format. Should be 64 hex characters (with or without 0x prefix)');
    }

    // Ensure 0x prefix
    return privateKey.startsWith('0x') ? privateKey : `0x${privateKey}`;
}

// Function to get and validate private key interactively
export async function getPrivateKeyInteractively(): Promise<string> {
    const privateKey = await promptForPrivateKey();
    return validatePrivateKey(privateKey);
}

// Function to handle Ctrl+C gracefully
export function setupGracefulExit(): void {
    process.on('SIGINT', () => {
        console.log('\n\n⚠️  Deployment interrupted by user');
        process.exit(0);
    });
}

// Function to validate network
export function validateNetwork(network: string | undefined): string {
    if (!network) {
        console.error('❌ NETWORK environment variable is required');
        console.error('   Available networks: sepolia, polygon, mainnet, fundora-sepolia');
        console.error('   Usage examples:');
        console.error('   NETWORK=sepolia npx ts-node <script>');
        console.error('   NETWORK=fundora-sepolia npx ts-node <script>');
        process.exit(1);
    }
    return network;
}

// Function to run forge script with common setup
export function runForgeScript(
    scriptPath: string,
    rpcUrl: string,
    privateKey: string,
    env: NodeJS.ProcessEnv,
    network: string,
): ChildProcess {
    const forgeArgs = ['script', scriptPath, '--rpc-url', rpcUrl, '--broadcast', '--private-key', privateKey, '--via-ir'];

    console.log('🔧 Running forge script...');
    console.log(`📄 Script: ${scriptPath}`);
    console.log(`🌐 Network: ${network}`);
    console.log(`📡 RPC: ${rpcUrl.replace(process.env.INFURA_API_KEY || '', '***')}`);
    console.log(`🚀 Broadcasting: Yes\n`);

    return spawn('forge', forgeArgs, {
        env,
        stdio: 'inherit',
        cwd: process.cwd(),
    });
}

// Function to handle forge process events
export function handleForgeProcess(forgeProcess: ChildProcess, network: string, contractType: string = 'contract'): void {
    forgeProcess.on('close', code => {
        if (code === 0) {
            console.log(`\n✅ ${contractType} deployment completed successfully!`);
            console.log(`🎉 Your ${contractType} is now live on ${network}!`);
            console.log('\n📝 Next steps:');
            console.log('   1. Check addresses.json for deployed contract addresses');
            console.log('   2. Verify contracts on block explorer');
            console.log('   3. Set up permissions and initial configurations');
        } else {
            console.error(`\n❌ ${contractType} deployment failed with exit code ${code}`);
            process.exit(code || 1);
        }
    });

    forgeProcess.on('error', error => {
        if ((error as any).code === 'ENOENT') {
            console.error('❌ Forge not found. Make sure Foundry is installed and in your PATH.');
            console.error('   Install from: https://getfoundry.sh/');
        } else {
            console.error('❌ Failed to start forge:', error.message);
        }
        process.exit(1);
    });
}
