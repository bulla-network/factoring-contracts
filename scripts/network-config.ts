// Shared network configurations for deployment and permissions scripts

export type NetworkConfig = {
    bullaClaim: string;
    underlyingAsset: string;
    underwriter: string;
    bullaDao: string;
    protocolFeeBps: number;
    adminFeeBps: number;
    poolName: string;
    targetYieldBps: number;
    poolTokenName: string;
    poolTokenSymbol: string;
    BullaClaimInvoiceProviderAdapterAddress?: string;
    factoringPermissionsAddress?: string;
    depositPermissionsAddress?: string;
    redeemPermissionsAddress?: string;
    bullaFrendLendAddress: string;
    bullaInvoiceAddress: string;
    bullaFactoringAddress?: string;
    aavePoolAddress?: string;
    writeNewAddresses: boolean;
};

// Complete configurations for deployments
export const sepoliaConfig: NetworkConfig = {
    bullaClaim: '0xb4b455d4dd9832c2ae6042fa11ec82b114e8a7e4', // Sepolia Address
    underlyingAsset: '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8', // Sepolia USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
    protocolFeeBps: 25,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Factoring Pool Sepolia Test v2.1',
    targetYieldBps: 730,
    poolTokenName: 'Bulla TCS Factoring Pool',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0x15ef2BD80BE2247C9007A35c761Ea9aDBe1063C5',
    factoringPermissionsAddress: '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e',
    depositPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
    redeemPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
    bullaFrendLendAddress: '0x330b6f37d9881ca4781ef70d662197ddb0d353b7',
    bullaInvoiceAddress: '0x6c4044597f2be6e1dc92217a49b0571c91025379',
    bullaFactoringAddress: '0xbc1dd527c3CF1302Cb189CaB9683Ef5CF27F0308',
    aavePoolAddress: '0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951', // Aave v3 Pool on Sepolia
    writeNewAddresses: true,
};

export const polygonConfig: NetworkConfig = {
    bullaClaim: '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4', // Polygon Address
    underlyingAsset: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359', // Polygon USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
    protocolFeeBps: 100,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Factoring Pool - Polygon V2',
    targetYieldBps: 1100, // 11%
    poolTokenName: 'Bulla TCS Factoring Pool Token',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0xB5B31E95f0C732450Bc869A6467A9941C8565b10',
    factoringPermissionsAddress: '0x72c1cD1C6A7132e58b334E269Ec5bE1adC1030d4',
    depositPermissionsAddress: '0xBB56c6E4e0812de05bf870941676F6467D964d5e',
    redeemPermissionsAddress: '0x0000000000000000000000000000000000000000',
    bullaFrendLendAddress: '0x0000000000000000000000000000000000000000',
    bullaInvoiceAddress: '0x0000000000000000000000000000000000000000',
    bullaFactoringAddress: '0xA7033191Eb07DC6205015075B204Ba0544bc460d',
    writeNewAddresses: true,
};

export const ethereumConfig: NetworkConfig = {
    bullaClaim: '0x127948A4286A67A0A5Cb56a2D0d54881077A4889', // Mainnet Address
    underlyingAsset: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', // Mainnet USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
    protocolFeeBps: 100,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Settlement Pool - Mainnet V2',
    targetYieldBps: 1100, // 11%
    poolTokenName: 'Bulla TCS Settlement Pool Token',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0xE14E624b29BcDa2ec409BBBf97037fEDe3803797',
    factoringPermissionsAddress: '0x1c534661326b41c8b8aab5631ECED6D9755ff192',
    depositPermissionsAddress: '0xeB0f09EEF3DCc3f35f605dAefa474e6caab96CD6',
    redeemPermissionsAddress: '0x0000000000000000000000000000000000000000',
    bullaFrendLendAddress: '0x0000000000000000000000000000000000000000',
    bullaInvoiceAddress: '0x0000000000000000000000000000000000000000',
    bullaFactoringAddress: '0x0af8C15D19058892cDEA66C8C74B7D7bB696FaD5',
    writeNewAddresses: true,
};

// Complete configurations for deployments
export const fundoraConfig: NetworkConfig = {
    bullaClaim: '0x36C5a95ABF732CD57A95F37b23348E79aA773016', // Sepolia Address
    underlyingAsset: '0x3894374b3ffd1DB45b760dD094963Dd1167e5568', // WYST
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
    protocolFeeBps: 10,
    adminFeeBps: 50,
    poolName: 'Fundora Management Pool V2.1',
    targetYieldBps: 900,
    poolTokenName: 'Fundora Management Token V2.1',
    poolTokenSymbol: 'FACT-V2_1',
    BullaClaimInvoiceProviderAdapterAddress: '0x9b8cC402955F401fD9f48c714420F41F191FC213',
    bullaFactoringAddress: '0x1E1d535a41515D3D2c29C1524C825236D67733E1',
    bullaFrendLendAddress: '0xf1735D81D174fDe0536178A0A2A0E0Ba366Dc231',
    bullaInvoiceAddress: '0x0C7781443B39cbf0186b7816db5CE183d75d8CE8',
    depositPermissionsAddress: '0x764E845528e177aF40D508F46E948d5440AaC13D',
    redeemPermissionsAddress: '0x764E845528e177aF40D508F46E948d5440AaC13D',
    factoringPermissionsAddress: '0x523e35a7A0c2f2e48E32bb6363090BB436Ac433F',
    writeNewAddresses: true,
};

// Complete configurations for deployments
export const baseConfig: NetworkConfig = {
    bullaClaim: '0x9d4EB59D166841FfbC66197ECAd8E70f2339905D',
    underlyingAsset: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xca591b3b53521ccde47d2da4e0ea151f8b81f6c1', // Bulla Safe's address
    protocolFeeBps: 10,
    adminFeeBps: 50,
    poolName: 'TCS Settlement Pool V2',
    targetYieldBps: 1050,
    poolTokenName: 'TCS Settlement Pool Token V2',
    poolTokenSymbol: 'BFT-TCS-V2',
    bullaFrendLendAddress: '0x03754cc78848FBc52130a8EEdD8d3d079F7Bb042',
    bullaInvoiceAddress: '0x662303A841C0DDe7383939417581cBf34BE9f01D',
    bullaFactoringAddress: '0x7c2Cc85Cb30844B81524E703f04a5eE98e3313FB',
    depositPermissionsAddress: '0xFCD0440E253A00FD938ce4a67fC3680aD2D685cf',
    redeemPermissionsAddress: '0xFCD0440E253A00FD938ce4a67fC3680aD2D685cf',
    factoringPermissionsAddress: '0x0313433613F24c73efc15c5c74408F40B462fd9e',
    writeNewAddresses: true,
};

// Helper function to get config based on network
export function getNetworkConfig(network: string) {
    if (!network) {
        throw new Error('Network parameter is required');
    }

    switch (network) {
        case 'sepolia':
            return sepoliaConfig;
        case 'polygon':
            return polygonConfig;
        case 'mainnet':
            return ethereumConfig;
        case 'fundora-sepolia':
            return fundoraConfig;
        case 'base':
            return baseConfig;
        default:
            throw new Error(`Unsupported network: ${network}`);
    }
}

// Utility functions for network operations
export function getRpcUrl(network: string): string {
    switch (network) {
        case 'sepolia':
        case 'fundora-sepolia':
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
        case 'fundora-sepolia':
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
        case 'fundora-sepolia':
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
