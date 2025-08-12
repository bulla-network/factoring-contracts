import { ethers } from 'hardhat';
import * as readline from 'readline';

// Function to prompt for private key
export function promptForPrivateKey(): Promise<string> {
    return new Promise(resolve => {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });

        // Hide input for private key
        const originalWrite = process.stdout.write;
        let hidden = false;

        process.stdout.write = function (string: any, encoding?: any, fd?: any): boolean {
            if (hidden && string !== '\n') {
                return originalWrite.call(process.stdout, '*', encoding, fd);
            }
            return originalWrite.call(process.stdout, string, encoding, fd);
        };

        rl.question('Enter private key (input will be hidden): ', privateKey => {
            hidden = false;
            process.stdout.write = originalWrite;
            console.log(); // New line after hidden input
            rl.close();
            resolve(privateKey.trim());
        });

        hidden = true;
    });
}

// Function to validate private key format
export function isValidPrivateKey(privateKey: string): boolean {
    try {
        // Remove 0x prefix if present
        const cleanKey = privateKey.startsWith('0x') ? privateKey.slice(2) : privateKey;

        // Check if it's 64 characters (32 bytes in hex)
        if (cleanKey.length !== 64) {
            return false;
        }

        // Check if it's valid hex
        if (!/^[0-9a-fA-F]+$/.test(cleanKey)) {
            return false;
        }

        // Try creating a wallet to validate
        new ethers.Wallet(privateKey);
        return true;
    } catch {
        return false;
    }
}

// Function to ensure private key is available for deployment
export async function ensurePrivateKey(): Promise<string> {
    // Check if environment variable is set
    if (process.env.DEPLOY_PK && isValidPrivateKey(process.env.DEPLOY_PK)) {
        console.log('Using private key from environment variable.');
        return process.env.DEPLOY_PK;
    }

    // Prompt for private key
    console.log('Private key not found in environment variables.');

    let privateKey: string;
    let attempts = 0;
    const maxAttempts = 3;

    do {
        if (attempts > 0) {
            console.log('Invalid private key format. Please try again.');
        }

        privateKey = await promptForPrivateKey();
        attempts++;

        if (attempts >= maxAttempts && !isValidPrivateKey(privateKey)) {
            throw new Error('Maximum attempts reached. Invalid private key provided.');
        }
    } while (!isValidPrivateKey(privateKey));

    // Ensure it has 0x prefix
    if (!privateKey.startsWith('0x')) {
        privateKey = '0x' + privateKey;
    }

    console.log('Private key validated successfully.');
    return privateKey;
}
