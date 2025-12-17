// Shared network and pool configurations for deployment and permissions scripts

// ============================================================================
// Types
// ============================================================================

const allPools = ['tcs', 'taram', 'fundora'] as const;
export type PoolName = typeof allPools[number];

/** Network-specific configuration (not tied to any pool) */
export type NetworkConfig = {
    bullaClaim: string;
    bullaDao: string;
    bullaFrendLendAddress: string;
    bullaInvoiceAddress: string;
    BullaClaimInvoiceProviderAdapterAddress?: string;
};

/** Pool-specific configuration (not tied to any network) */
export type PoolConfig = {
    protocolFeeBps: number;
    adminFeeBps: number;
    targetYieldBps: number;
};

/** Deployed pool configuration (specific to network + pool combination) */
export type DeployedPoolConfig = {
    underlyingAsset: string;
    poolDisplayName: string;
    poolTokenName: string;
    poolTokenSymbol: string;
    underwriter: string;
    factoringPermissionsAddress?: string;
    depositPermissionsAddress?: string;
    redeemPermissionsAddress?: string;
    bullaFactoringAddress?: string;
    writeNewAddresses: boolean;
};

/** Combined config returned by getConfig() */
export type FullConfig = NetworkConfig & PoolConfig & DeployedPoolConfig & { poolName: PoolName; network: string };

// ============================================================================
// Network Configurations (Network-only, no pool info)
// ============================================================================

export const networkConfigs: Record<string, NetworkConfig> = {
    sepolia: {
        bullaClaim: '0x0d9EF9d436fF341E500360a6B5E5750aB85BCCB6',
        bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
        bullaFrendLendAddress: '0x4d6A66D32CF34270e4cc9C9F201CA4dB650Be3f2',
        bullaInvoiceAddress: '0xa2c4B7239A0d179A923751cC75277fe139AB092F',
        BullaClaimInvoiceProviderAdapterAddress: '0x2c6c46d6b1b5121b0072c8b9f4eb836fe1252f78',
    },
    polygon: {
        bullaClaim: '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4',
        bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
        bullaFrendLendAddress: '0x0000000000000000000000000000000000000000',
        bullaInvoiceAddress: '0x0000000000000000000000000000000000000000',
        BullaClaimInvoiceProviderAdapterAddress: '0xB5B31E95f0C732450Bc869A6467A9941C8565b10',
    },
    mainnet: {
        bullaClaim: '0x127948A4286A67A0A5Cb56a2D0d54881077A4889',
        bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
        bullaFrendLendAddress: '0x0000000000000000000000000000000000000000',
        bullaInvoiceAddress: '0x0000000000000000000000000000000000000000',
        BullaClaimInvoiceProviderAdapterAddress: '0xE14E624b29BcDa2ec409BBBf97037fEDe3803797',
    },
    base: {
        bullaClaim: '0x9d4EB59D166841FfbC66197ECAd8E70f2339905D',
        bullaDao: '0xca591b3b53521ccde47d2da4e0ea151f8b81f6c1', // Bulla Safe's address
        bullaFrendLendAddress: '0x03754cc78848FBc52130a8EEdD8d3d079F7Bb042',
        bullaInvoiceAddress: '0x662303A841C0DDe7383939417581cBf34BE9f01D',
    },
};

// ============================================================================
// Pool Configurations (Pool-only, network-agnostic)
// ============================================================================

export const poolConfigs: Record<PoolName, PoolConfig> = {
    tcs: {
        protocolFeeBps: 25,
        adminFeeBps: 50,
        targetYieldBps: 730,
    },
    taram: {
        protocolFeeBps: 25,
        adminFeeBps: 50,
        targetYieldBps: 800,
    },
    fundora: {
        protocolFeeBps: 10,
        adminFeeBps: 50,
        targetYieldBps: 900,
    },
};

// ============================================================================
// Deployed Pool Configurations (Network + Pool specific)
// ============================================================================

/**
 * Get deployed pool configuration for a specific network + pool combination
 * Returns undefined if the pool is not deployed on that network
 */
function getDeploymentConfig(network: string, pool: PoolName): DeployedPoolConfig | undefined {
    switch (network) {
        case 'sepolia':
            switch (pool) {
                case 'tcs':
                    return {
                        underlyingAsset: '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8', // Sepolia USDC
                        poolDisplayName: 'Bulla TCS Factoring Pool Sepolia Test v2.1',
                        poolTokenName: 'Bulla TCS Factoring Pool',
                        poolTokenSymbol: 'BFT-TCS',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        factoringPermissionsAddress: '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e',
                        depositPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
                        redeemPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
                        bullaFactoringAddress: '0xbc1dd527c3CF1302Cb189CaB9683Ef5CF27F0308',
                        writeNewAddresses: true,
                    };
                case 'fundora':
                    return {
                        underlyingAsset: '0x3894374b3ffd1DB45b760dD094963Dd1167e5568', // WYST
                        poolDisplayName: 'Fundora Management Pool V2.1',
                        poolTokenName: 'Fundora Management Token V2.1',
                        poolTokenSymbol: 'FACT-V2_1',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        depositPermissionsAddress: '0x764E845528e177aF40D508F46E948d5440AaC13D',
                        redeemPermissionsAddress: '0x764E845528e177aF40D508F46E948d5440AaC13D',
                        factoringPermissionsAddress: '0x523e35a7A0c2f2e48E32bb6363090BB436Ac433F',
                        bullaFactoringAddress: '0x59973c8dbb88c7d3f5480175cef253c771ccb3ef',
                        writeNewAddresses: true,
                    };
                default:
                    return undefined;
            }

        case 'polygon':
            switch (pool) {
                case 'tcs':
                    return {
                        underlyingAsset: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359', // Polygon USDC
                        poolDisplayName: 'Bulla TCS Factoring Pool - Polygon V2',
                        poolTokenName: 'Bulla TCS Factoring Pool Token',
                        poolTokenSymbol: 'BFT-TCS',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        factoringPermissionsAddress: '0x72c1cD1C6A7132e58b334E269Ec5bE1adC1030d4',
                        depositPermissionsAddress: '0xBB56c6E4e0812de05bf870941676F6467D964d5e',
                        redeemPermissionsAddress: '0x0000000000000000000000000000000000000000',
                        bullaFactoringAddress: '0xA7033191Eb07DC6205015075B204Ba0544bc460d',
                        writeNewAddresses: true,
                    };
                default:
                    return undefined;
            }

        case 'mainnet':
            switch (pool) {
                case 'tcs':
                    return {
                        underlyingAsset: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', // Mainnet USDC
                        poolDisplayName: 'Bulla TCS Settlement Pool - Mainnet V2',
                        poolTokenName: 'Bulla TCS Settlement Pool Token',
                        poolTokenSymbol: 'BFT-TCS',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        factoringPermissionsAddress: '0x1c534661326b41c8b8aab5631ECED6D9755ff192',
                        depositPermissionsAddress: '0xeB0f09EEF3DCc3f35f605dAefa474e6caab96CD6',
                        redeemPermissionsAddress: '0x0000000000000000000000000000000000000000',
                        bullaFactoringAddress: '0x0af8C15D19058892cDEA66C8C74B7D7bB696FaD5',
                        writeNewAddresses: true,
                    };
                default:
                    return undefined;
            }

        case 'base':
            switch (pool) {
                case 'tcs':
                    return {
                        underlyingAsset: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // USDC
                        poolDisplayName: 'TCS Settlement Pool V2',
                        poolTokenName: 'TCS Settlement Pool Token V2',
                        poolTokenSymbol: 'BFT-TCS-V2',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        bullaFactoringAddress: '0x7c2Cc85Cb30844B81524E703f04a5eE98e3313FB',
                        depositPermissionsAddress: '0xFCD0440E253A00FD938ce4a67fC3680aD2D685cf',
                        redeemPermissionsAddress: '0xFCD0440E253A00FD938ce4a67fC3680aD2D685cf',
                        factoringPermissionsAddress: '0x0313433613F24c73efc15c5c74408F40B462fd9e',
                        writeNewAddresses: true,
                    };
                default:
                    return undefined;
            }

        default:
            return undefined;
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Get full configuration for a network and pool combination
 * @param network - Network name (sepolia, polygon, mainnet, base)
 * @param pool - Pool name (tcs, taram, fundora). Defaults to 'tcs'
 * @throws Error if network is unsupported, pool doesn't exist, or pool is not deployed on the network
 */
export function getConfig(network: string, pool: PoolName = 'tcs'): FullConfig {
    if (!network) {
        throw new Error('Network parameter is required');
    }

    const networkConfig = networkConfigs[network];
    if (!networkConfig) {
        throw new Error(`Unsupported network: ${network}. Available: ${Object.keys(networkConfigs).join(', ')}`);
    }

    const poolConfig = poolConfigs[pool];
    if (!poolConfig) {
        throw new Error(`Unsupported pool: ${pool}. Available: ${Object.keys(poolConfigs).join(', ')}`);
    }

    const deployedPoolConfig = getDeploymentConfig(network, pool);
    if (!deployedPoolConfig) {
        throw new Error(`Pool '${pool}' is not deployed on network '${network}'`);
    }

    return {
        ...networkConfig,
        ...poolConfig,
        ...deployedPoolConfig,
        poolName: pool,
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

export function getRpcUrl(network: string): string {
    switch (network) {
        case 'sepolia':
            return `https://rpc.ankr.com/eth_sepolia/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc`;
        case 'polygon':
            return 'https://polygon-rpc.com/';
        case 'mainnet':
            return `https://go.getblock.io/${process.env.MAINNET_GETBLOCK_API_KEY}`;
        case 'base':
            return 'https://rpc.ankr.com/base/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc';
        default:
            throw new Error(`Unsupported network: ${network}`);
    }
}

export function getEtherscanApiKey(network: string): string {
    switch (network) {
        case 'sepolia':
        case 'base':
        case 'mainnet':
            return process.env.ETHERSCAN_API_KEY!;
        case 'polygon':
            return process.env.POLYGONSCAN_API_KEY!;
        default:
            throw new Error(`No Etherscan API key configured for network: ${network}`);
    }
}

export function getChainId(network: string): number {
    switch (network) {
        case 'sepolia':
            return 11155111;
        case 'polygon':
            return 137;
        case 'mainnet':
            return 1;
        case 'base':
            return 8453;
        default:
            throw new Error(`Unknown chain ID for network: ${network}`);
    }
}

export function getAvailablePools(network: string): PoolName[] {
    return allPools.filter(pool => getDeploymentConfig(network, pool) !== undefined);
}

export function getAvailableNetworks(): string[] {
    return Object.keys(networkConfigs);
}

export function getPoolConfig(pool: PoolName): PoolConfig {
    const config = poolConfigs[pool];
    if (!config) {
        throw new Error(`Unsupported pool: ${pool}. Available: ${Object.keys(poolConfigs).join(', ')}`);
    }
    return config;
}

export function getNetworkOnlyConfig(network: string): NetworkConfig {
    const config = networkConfigs[network];
    if (!config) {
        throw new Error(`Unsupported network: ${network}. Available: ${Object.keys(networkConfigs).join(', ')}`);
    }
    return config;
}

export function getDeployedPoolConfig(network: string, pool: PoolName): DeployedPoolConfig | undefined {
    return getDeploymentConfig(network, pool);
}

export function isPoolDeployed(network: string, pool: PoolName): boolean {
    return getDeploymentConfig(network, pool) !== undefined;
}
