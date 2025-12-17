import * as readline from 'readline';
import { getAvailableNetworks, getAvailablePools, PoolName } from '../network-config';

/**
 * Prompt user to select from a list of options
 */
export function promptSelect(question: string, options: string[]): Promise<string> {
    return new Promise(resolve => {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });

        console.log(`\n${question}`);
        options.forEach((option, index) => {
            console.log(`  ${index + 1}. ${option}`);
        });

        const askQuestion = () => {
            rl.question('\nEnter your choice (number or name): ', answer => {
                const trimmed = answer.trim();

                // Check if it's a number
                const num = parseInt(trimmed);
                if (!isNaN(num) && num >= 1 && num <= options.length) {
                    rl.close();
                    resolve(options[num - 1]);
                    return;
                }

                // Check if it's a valid option name
                if (options.includes(trimmed)) {
                    rl.close();
                    resolve(trimmed);
                    return;
                }

                console.log(`❌ Invalid choice. Please enter a number (1-${options.length}) or one of: ${options.join(', ')}`);
                askQuestion();
            });
        };

        askQuestion();
    });
}

/**
 * Get network from environment or prompt user
 */
export async function getNetworkInteractive(): Promise<string> {
    const network = process.env.NETWORK;
    if (network) {
        const availableNetworks = getAvailableNetworks();
        if (!availableNetworks.includes(network)) {
            throw new Error(`Invalid network: ${network}. Available networks: ${availableNetworks.join(', ')}`);
        }
        return network;
    }

    const availableNetworks = getAvailableNetworks();
    return await promptSelect('🌐 Select a network:', availableNetworks);
}

/**
 * Get pool from environment or prompt user
 */
export async function getPoolInteractive(network: string): Promise<PoolName> {
    const pool = process.env.POOL;
    if (pool) {
        const availablePools = getAvailablePools(network);
        if (!availablePools.includes(pool as PoolName)) {
            throw new Error(`Pool '${pool}' is not deployed on network '${network}'. Available pools: ${availablePools.join(', ')}`);
        }
        return pool as PoolName;
    }

    const availablePools = getAvailablePools(network);

    if (availablePools.length === 0) {
        throw new Error(`No pools deployed on network: ${network}`);
    }

    if (availablePools.length === 1) {
        console.log(`\n📊 Using the only available pool: ${availablePools[0]}`);
        return availablePools[0];
    }

    return (await promptSelect('📊 Select a pool:', availablePools)) as PoolName;
}

/**
 * Get both network and pool interactively
 */
export async function getNetworkAndPoolInteractive(): Promise<{ network: string; pool: PoolName }> {
    const network = await getNetworkInteractive();
    const pool = await getPoolInteractive(network);

    console.log(`\n✅ Selected: ${network} / ${pool}\n`);

    return { network, pool };
}
