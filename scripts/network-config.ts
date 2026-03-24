// Shared network and pool configurations for deployment and permissions scripts

// ============================================================================
// Global Constants
// ============================================================================

/** Default protocol fee in basis points (30 bps = 0.30%) */
export const DEFAULT_PROTOCOL_FEE_BPS = 30;

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
    bullaFactoringFactoryAddress?: string;
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
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x4d6A66D32CF34270e4cc9C9F201CA4dB650Be3f2',
        bullaInvoiceAddress: '0xa2c4B7239A0d179A923751cC75277fe139AB092F',
        BullaClaimInvoiceProviderAdapterAddress: '0x2c6c46d6b1b5121b0072c8b9f4eb836fe1252f78',
    },
    polygon: {
        bullaClaim: '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x0000000000000000000000000000000000000000',
        bullaInvoiceAddress: '0x0000000000000000000000000000000000000000',
        BullaClaimInvoiceProviderAdapterAddress: '0xB5B31E95f0C732450Bc869A6467A9941C8565b10',
    },
    mainnet: {
        bullaClaim: '0x10a55a4dbd24fa188eed98a2adae2ebff0ef1219',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x1097b7ecf0721aaffff147cf7bec154422896317',
        bullaInvoiceAddress: '0xfe2631bcb3e622750b6fbb605a416173ffa3a770',
        BullaClaimInvoiceProviderAdapterAddress: '0x74c62f475464a03a462578d65629240b34221c1b',
    },
    base: {
        bullaClaim: '0x8D59E594a3e4D0647C15887Cde5ECBfBE583b441',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x777A7966464a4E5684FE95025aDb2AD56bdaE77B',
        bullaInvoiceAddress: '0x1E1d535a41515D3D2c29C1524C825236D67733E1',
        BullaClaimInvoiceProviderAdapterAddress: '0x4d4f494f4e6232d2be0a055359eb29edb17ae0ca',
    },
    arbitrum: {
        bullaClaim: '0xb58f4f651553d51d95c69f59364a9ee1ca554b7e',
        bullaDao: '0x47Ee085AC0Cdd254D4BFeca3405cD970f44728AB', // Bulla Protocol Safe's address
        bullaFrendLendAddress: '0x1a34dfd1ee17130228452f3d9cdda5908865d22d',
        bullaInvoiceAddress: '0x74c62f475464a03a462578d65629240b34221c1b',
        BullaClaimInvoiceProviderAdapterAddress: '0x2c6c46d6b1b5121b0072c8b9f4eb836fe1252f78',
    },
};

// ============================================================================
// Pool Configurations (Pool-only, network-agnostic)
// ============================================================================

export const poolConfigs: Record<PoolName, PoolConfig> = {
    tcs: {
        protocolFeeBps: 30,
        adminFeeBps: 0,
        targetYieldBps: 792,
    },
    taram: {
        protocolFeeBps: 30,
        adminFeeBps: 50,
        targetYieldBps: 800,
    },
    fundora: {
        protocolFeeBps: 30,
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
                        underlyingAsset: '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8', // USDC
                        poolDisplayName: 'Test Pool V2.1',
                        poolTokenName: 'Test Token V2.1',
                        poolTokenSymbol: 'BFT-V2_1',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        depositPermissionsAddress: '0x764E845528e177aF40D508F46E948d5440AaC13D',
                        redeemPermissionsAddress: '0x764E845528e177aF40D508F46E948d5440AaC13D',
                        factoringPermissionsAddress: '0x523e35a7A0c2f2e48E32bb6363090BB436Ac433F',
                        bullaFactoringAddress: '0xa5e94f122d421c9579a5cb1e687f55e109ba270b',
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
                        underlyingAsset: '0x6c3ea9036406852006290770BEdFcAbA0e23A0e8', // Mainnet PyUSD
                        poolDisplayName: 'TCS Settlement Pool - Mainnet V2.1',
                        poolTokenName: 'TCS Settlement Pool Token V2.1',
                        poolTokenSymbol: 'BFT-TCS-V2_1',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        factoringPermissionsAddress: '0x1c534661326b41c8b8aab5631ECED6D9755ff192',
                        depositPermissionsAddress: '0xeB0f09EEF3DCc3f35f605dAefa474e6caab96CD6',
                        redeemPermissionsAddress: '0xeB0f09EEF3DCc3f35f605dAefa474e6caab96CD6',
                        bullaFactoringAddress: '0x1a34dfd1ee17130228452f3d9cdda5908865d22d',
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
                        depositPermissionsAddress: '0xFCD0440E253A00FD938ce4a67fC3680aD2D685cf',
                        redeemPermissionsAddress: '0xFCD0440E253A00FD938ce4a67fC3680aD2D685cf',
                        factoringPermissionsAddress: '0x0313433613F24c73efc15c5c74408F40B462fd9e',
                        bullaFactoringAddress: '0xc65abf8aba06510f777be4ba2c29da4d93257d42',
<<<<<<< HEAD
                        writeNewAddresses: true,
                    };
                default:
                    return undefined;
            }

        case 'arbitrum':
            switch (pool) {
                case 'tcs':
                    return {
                        underlyingAsset: '0x46850aD61C2B7d64d08c9C754F45254596696984', // pyUSD
                        poolDisplayName: 'TCS Settlement Pool - Arbitrum V2.1',
                        poolTokenName: 'TCS Settlement Pool Token V2.1',
                        poolTokenSymbol: 'BFT-TCS-V2_1',
                        underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
                        factoringPermissionsAddress: '0x3204562dbb6465193525e0da1e5e016643b2b117',
                        depositPermissionsAddress: '0xb842d5c5200841ef153100cc4d9fcac47620dd0a',
                        redeemPermissionsAddress: '0xb842d5c5200841ef153100cc4d9fcac47620dd0a',
                        bullaFactoringAddress: '0x30fbdae8d1a2946ca00137eaf3de9b512d1ee859',
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
            return 'https://rpc.ankr.com/polygon/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc';
        case 'mainnet':
            return `https://go.getblock.io/${process.env.MAINNET_GETBLOCK_API_KEY}`;
        case 'base':
            return 'https://rpc.ankr.com/base/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc';
        case 'arbitrum':
            return 'https://rpc.ankr.com/arbitrum/ba1559bd45627ea35b516452751976567e0fd8864450470f207b8d01cbc3f4dc';
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
        case 'arbitrum':
            return process.env.ARBISCAN_API_KEY!;
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
        case 'arbitrum':
            return 42161;
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
