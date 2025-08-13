// Shared network configurations for deployment and permissions scripts

// Complete configurations for deployments
export const sepoliaConfig = {
    bullaClaim: '0x3702D060cbB102b6AebF40B40880F77BeF3d7225', // Sepolia Address
    underlyingAsset: '0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8', // Sepolia USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
    protocolFeeBps: 25,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Factoring Pool Sepolia Test v2',
    taxBps: 0,
    targetYieldBps: 730,
    poolTokenName: 'Bulla TCS Factoring Pool',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0x15ef2BD80BE2247C9007A35c761Ea9aDBe1063C5',
    factoringPermissionsAddress: '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e',
    depositPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
    bullaFactoringAddress: '0xDF0fCe31285dcAB9124bF763AB9E5466723BeF35',
    writeNewAddresses: true,
    setImpairReserve: true,
    usePermissionsWithReconcile: false,
};

export const sepoliaFundoraConfig = {
    bullaClaim: '0x3702D060cbB102b6AebF40B40880F77BeF3d7225', // Sepolia Address
    underlyingAsset: '0x3894374b3ffd1DB45b760dD094963Dd1167e5568', // New WYST address
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0x89e03e7980c92fd81ed3a9b72f5c73fdf57e5e6d', // Mike's address
    protocolFeeBps: 25,
    adminFeeBps: 50,
    poolName: 'Bulla Fundora Factoring Pool Sepolia Test',
    taxBps: 0,
    targetYieldBps: 730,
    poolTokenName: 'Fundora Sepolia Test Token',
    poolTokenSymbol: 'BFT-FNDRA',
    BullaClaimInvoiceProviderAdapterAddress: '0x15ef2BD80BE2247C9007A35c761Ea9aDBe1063C5',
    factoringPermissionsAddress: '0x996e2beFD170CeB741b0072AE97E524Bdf410E9e',
    depositPermissionsAddress: '0xB39bF6Fcd9bd97F7616FAD7b6118Fc2E911eA1d8',
    bullaFactoringAddress: '0x9efBa474E79e7e37C87AB5CAf3D32347Bb9e604F',
    writeNewAddresses: true,
    setImpairReserve: true,
    usePermissionsWithReconcile: false,
};

export const polygonConfig = {
    bullaClaim: '0x5A809C17d33c92f9EFF31e579E9DeDF247e1EBe4', // Polygon Address
    underlyingAsset: '0x3c499c542cef5e3811e1192ce70d8cc03d5c3359', // Polygon USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
    protocolFeeBps: 100,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Factoring Pool - Polygon V2',
    taxBps: 0,
    targetYieldBps: 1100, // 11%
    poolTokenName: 'Bulla TCS Factoring Pool Token',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0xB5B31E95f0C732450Bc869A6467A9941C8565b10',
    factoringPermissionsAddress: '0x72c1cD1C6A7132e58b334E269Ec5bE1adC1030d4',
    depositPermissionsAddress: '0xBB56c6E4e0812de05bf870941676F6467D964d5e',
    bullaFactoringAddress: '0xA7033191Eb07DC6205015075B204Ba0544bc460d',
    writeNewAddresses: true,
    setImpairReserve: false,
    usePermissionsWithReconcile: false,
};

export const ethereumConfig = {
    bullaClaim: '0x127948A4286A67A0A5Cb56a2D0d54881077A4889', // Mainnet Address
    underlyingAsset: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48', // Mainnet USDC
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
    protocolFeeBps: 100,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Settlement Pool - Mainnet V2',
    taxBps: 0,
    targetYieldBps: 1100, // 11%
    poolTokenName: 'Bulla TCS Settlement Pool Token',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0xE14E624b29BcDa2ec409BBBf97037fEDe3803797',
    factoringPermissionsAddress: '0x1c534661326b41c8b8aab5631ECED6D9755ff192',
    depositPermissionsAddress: '0xeB0f09EEF3DCc3f35f605dAefa474e6caab96CD6',
    bullaFactoringAddress: '0x0af8C15D19058892cDEA66C8C74B7D7bB696FaD5',
    writeNewAddresses: true,
    setImpairReserve: false,
    usePermissionsWithReconcile: false,
};

export const baseConfig = {
    bullaClaim: '0x873C25e47f3C5e4bC524771DFed53B5B36ad5eA2', // Base Address
    underlyingAsset: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // Base USDC, https://www.circle.com/pt-br/multi-chain-usdc
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
    protocolFeeBps: 100,
    adminFeeBps: 50,
    poolName: 'Bulla TCS Settlement Pool - Base',
    taxBps: 0,
    targetYieldBps: 1100, // 11%
    poolTokenName: 'Bulla TCS Settlement Pool Token',
    poolTokenSymbol: 'BFT-TCS',
    BullaClaimInvoiceProviderAdapterAddress: '0xA7033191Eb07DC6205015075B204Ba0544bc460d',
    factoringPermissionsAddress: '0x3287d25C2Ff250467E4e375886FEe49A936C2F1c',
    depositPermissionsAddress: '0x7B3776dcCDb3965Ab9d414F5c9Db5a07177Ea449',
    bullaFactoringAddress: '0x1968f9440724B3148C8152190eeCb18a2F3b2eec',
    writeNewAddresses: true,
    setImpairReserve: true,
    usePermissionsWithReconcile: false,
};

export const taramRedbellyConfig = {
    bullaClaim: '0x1c534661326b41c8b8aab5631ECED6D9755ff192',
    underlyingAsset: '0x8201c02d4AB2214471E8C3AD6475C8b0CD9F2D06', // USDC.e
    underwriter: '0x5d72984B2e1170EAA0DA4BC22B25C87729C5EBB3',
    bullaDao: '0xD52199A8a2f94d0317641bA8a93d46C320403793',
    protocolFeeBps: 1, // Minimum required by contract (>0)
    adminFeeBps: 100,
    poolName: 'TARAM Funding Pool - Redbelly',
    taxBps: 0,
    targetYieldBps: 1500, // 15%
    poolTokenName: 'TARAM Funding Pool',
    poolTokenSymbol: 'BFT-TARAM',
    BullaClaimInvoiceProviderAdapterAddress: '0x6EB612cDEA6833bf3Df593f1F381043Be86543ee',
    factoringPermissionsAddress: '0x03754cc78848FBc52130a8EEdD8d3d079F7Bb042',
    depositPermissionsAddress: '0x772b675A4180B4F48d9D816619620664f90Cf281',
    bullaFactoringAddress: '0x8f5952d2122A8DF42a3dcB5286D7576ff640cF5D',
    writeNewAddresses: true,
    setImpairReserve: false,
    usePermissionsWithReconcile: true,
};

// Helper function to get config based on network
export function getNetworkConfig(network: string) {
    if (!network) {
        throw new Error('Network parameter is required');
    }

    switch (network) {
        case 'sepolia':
            return sepoliaConfig;
        case 'sepoliaFundora':
            return sepoliaFundoraConfig;
        case 'polygon':
            return polygonConfig;
        case 'mainnet':
            return ethereumConfig;
        case 'base':
            return baseConfig;
        case 'redbelly':
            return taramRedbellyConfig;
        default:
            throw new Error(`Unsupported network: ${network}`);
    }
}
