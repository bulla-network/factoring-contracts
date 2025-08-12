require('dotenv').config({ path: './.env' });
import '@nomicfoundation/hardhat-verify';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-solhint';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import 'hardhat-deploy';
import 'hardhat-gas-reporter';
import { HardhatUserConfig } from 'hardhat/types';

interface HardhatEtherscanConfig {
    apiKey: string | Record<string, string>;
    customChains: {
        network: string;
        chainId: number;
        urls: {
            apiURL: string;
            browserURL: string;
        };
    }[];
}

interface CustomHardhatConfig extends HardhatUserConfig {
    etherscan: HardhatEtherscanConfig;
}

// Get private key from environment or use dummy for local networks
function getPrivateKey(): string {
    // Check if we're running a task that needs a private key
    const needsPrivateKey = process.argv.some(arg => arg.includes('--network') && !arg.includes('hardhat') && !arg.includes('localhost'));

    if (!needsPrivateKey) {
        // Return dummy key for local/hardhat networks
        return '0x0000000000000000000000000000000000000000000000000000000000000001';
    }

    // Use environment variable if available (for CI/automated deployments)
    if (process.env.DEPLOY_PK) {
        return process.env.DEPLOY_PK;
    }

    // Return placeholder that will be handled by deployment scripts
    // This allows hardhat config to load without requiring immediate input
    return '0x0000000000000000000000000000000000000000000000000000000000000001';
}

const INFURA_API_KEY = process.env.INFURA_API_KEY!;
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY!;
const POLYGONSCAN_API_KEY = process.env.POLYGONSCAN_API_KEY!;
const BASESCAN_API_KEY = process.env.BASESCAN_API_KEY!;
const GET_BLOCK_API_KEY = process.env.GET_BLOCK_API_KEY!;
const MAINNET_GETBLOCK_API_KEY = process.env.MAINNET_GETBLOCK_API_KEY!;
const COINMARKETCAP_API = process.env.COINMARKETCAP_API!;
const DEPLOYER_ADDRESS = process.env.DEPLOYER_ADDRESS!;

// Get the private key for deployment
const DEPLOY_PK = getPrivateKey();

const config: CustomHardhatConfig = {
    defaultNetwork: 'hardhat',
    solidity: {
        compilers: [
            {
                version: '0.8.7',
                settings: {
                    optimizer: { enabled: true, runs: 200 },
                    viaIR: true,
                    outputSelection: { '*': { '*': ['abi', 'evm.bytecode'] } },
                },
            },
            {
                version: '0.8.3',
                settings: {
                    optimizer: { enabled: true, runs: 200 },
                    viaIR: true,
                    outputSelection: { '*': { '*': ['abi', 'evm.bytecode'] } },
                },
            },
            {
                version: '0.8.20',
                settings: {
                    optimizer: { enabled: true, runs: 200 },
                    viaIR: true,
                    outputSelection: { '*': { '*': ['abi', 'evm.bytecode'] } },
                },
            },
        ],
    },
    typechain: {
        outDir: 'typechain-types',
        target: 'ethers-v5',
        alwaysGenerateOverloads: false,
        externalArtifacts: [],
        dontOverrideCompile: false,
    },
    networks: {
        /** comment out this hardhat config if running tests */
        // hardhat: {
        //   mining: {
        //     auto: false,
        //     interval: 1000,
        //   },
        // },
        /** ^^^ */
        mainnet: {
            url: `https://go.getblock.io/${MAINNET_GETBLOCK_API_KEY}`,
            accounts: [DEPLOY_PK],
            chainId: 1,
        },
        rinkeby: {
            url: `https://rinkeby.infura.io/v3/${INFURA_API_KEY}`,
            accounts: [DEPLOY_PK],
            chainId: 4,
        },
        goerli: {
            url: `https://goerli.infura.io/v3/${INFURA_API_KEY}`,
            accounts: [DEPLOY_PK],
            chainId: 5,
        },
        sepolia: {
            url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
            accounts: [DEPLOY_PK],
            chainId: 11155111,
        },
        base_goerli: {
            url: `https://goerli.base.org`,
            accounts: [DEPLOY_PK],
            chainId: 84531,
        },
        base: {
            url: `https://mainnet.base.org`,
            accounts: [DEPLOY_PK],
            chainId: 8453,
        },
        xdai: {
            url: 'https://rpc.gnosischain.com/',
            accounts: [DEPLOY_PK],
            chainId: 100,
        },
        rsk: {
            url: `https://rsk.getblock.io/${GET_BLOCK_API_KEY}/mainnet/`,
            accounts: [DEPLOY_PK],
            chainId: 30,
        },
        polygon: {
            url: 'https://polygon-rpc.com/',
            accounts: [DEPLOY_PK],
            chainId: 137,
            gasPrice: 80000000000,
        },
        harmony_testnet: {
            url: 'https://api.s0.b.hmny.io',
            accounts: [DEPLOY_PK],
            chainId: 1666700000,
        },
        harmony: {
            url: 'https://a.api.s0.t.hmny.io',
            accounts: [DEPLOY_PK],
            chainId: 1666600000,
        },
        avalanche_cChain: {
            url: 'https://api.avax.network/ext/bc/C/rpc',
            accounts: [DEPLOY_PK],
            chainId: 43114,
        },
        celo: {
            url: `https://forno.celo.org`,
            accounts: [DEPLOY_PK],
            chainId: 42220,
        },
        aurora: {
            url: `https://mainnet.aurora.dev`,
            accounts: [DEPLOY_PK],
            chainId: 1313161554,
        },
        moonbeam: {
            url: `https://rpc.api.moonbeam.network`,
            accounts: [DEPLOY_PK],
            chainId: 1284,
        },
        arbitrum: {
            url: `https://arb1.arbitrum.io/rpc`,
            accounts: [DEPLOY_PK],
            chainId: 42161,
        },
        fuse: {
            url: `https://rpc.fuse.io`,
            accounts: [DEPLOY_PK],
            chainId: 122,
        },
        optimism: {
            url: 'https://mainnet.optimism.io',
            accounts: [DEPLOY_PK],
            chainId: 10,
        },
        bnb: {
            url: `https://bsc-dataseed.binance.org/`,
            accounts: [DEPLOY_PK],
            chainId: 56,
        },
        redbelly: {
            url: `https://governors.mainnet.redbelly.network`,
            accounts: [DEPLOY_PK],
            chainId: 151,
        },
    },
    namedAccounts: {
        deployer: {
            default: DEPLOYER_ADDRESS,
        },
    },
    gasReporter: {
        enabled: true,
        currency: 'USD',
        gasPrice: 1,
        coinmarketcap: process.env.COINMARKETCAP_API,
        outputFile: 'gas-report.txt',
        noColors: true,
        excludeContracts: [],
        src: './contracts',
    },
    etherscan: {
        apiKey: ETHERSCAN_API_KEY,
        customChains: [
            {
                network: 'base',
                chainId: 8453,
                urls: {
                    apiURL: 'https://api.basescan.org/api',
                    browserURL: 'https://basescan.org',
                },
            },
            {
                network: 'redbelly',
                chainId: 151,
                urls: {
                    apiURL: 'https://api.routescan.io/v2/network/redbelly/evm/1/etherscan/api',
                    browserURL: 'https://redbelly.routescan.io',
                },
            },
        ],
    },
};
export default config;
