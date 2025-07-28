# Bulla Factoring Contracts

A sophisticated invoice factoring protocol built on Ethereum that enables investors to pool funds for factoring invoices, built as an ERC4626-compatible vault with advanced liquidity management capabilities.

## Overview

The Bulla Factoring system consists of two main components:

-   **BullaFactoringV2**: An ERC4626 vault that pools investor funds to factor invoices for yield generation
-   **RedemptionQueue**: A FIFO queue manager that handles redemption requests when vault liquidity is insufficient

### Key Features

-   🏦 **ERC4626 Vault Compatibility** - Standard vault interface for DeFi integrations
-   📄 **Invoice Factoring** - Direct funding of invoices with yield generation
-   🔄 **Redemption Queue** - Efficient FIFO queue for managing liquidity constraints
-   🤝 **BullaFrendLend Integration** - Direct loan offer and management capabilities
-   💰 **Dynamic Fee System** - Automated fee calculation and distribution
-   🛡️ **Permission Controls** - Role-based access control with DAO governance
-   📊 **Impairment Management** - Risk management for non-performing invoices

## Architecture

### Core Contracts

| Contract                   | Description                                |
| -------------------------- | ------------------------------------------ |
| `BullaFactoringV2.sol`     | Main ERC4626 vault for invoice factoring   |
| `RedemptionQueue.sol`      | FIFO queue manager for redemption requests |
| `FactoringFundManager.sol` | Fund management and allocation logic       |
| `FactoringPermissions.sol` | Permission and access control system       |
| `DepositPermissions.sol`   | Deposit authorization controls             |

### Interface Contracts

| Interface                     | Purpose                      |
| ----------------------------- | ---------------------------- |
| `IBullaFactoring.sol`         | Main contract interface      |
| `IRedemptionQueue.sol`        | Queue contract interface     |
| `IInvoiceProviderAdapter.sol` | Invoice provider integration |

## Requirements

### System Requirements

-   **Node.js** 16+
-   **Git** with submodule support
-   **Foundry** (latest version recommended)

### Development Dependencies

-   **Forge** - Smart contract compilation and testing
-   **Yarn** - Package management and Hardhat tooling
-   **TypeScript** - Type definitions and deployment scripts

## Installation

1. **Clone the repository with submodules:**

    ```bash
    git clone --recursive https://github.com/bulla-network/factoring-contracts.git
    cd factoring-contracts
    ```

2. **Install Node.js dependencies:**

    ```bash
    yarn install
    ```

3. **Install Foundry dependencies:**

    ```bash
    forge install
    ```

4. **Update dependencies (if needed):**
    ```bash
    make update
    ```

## Building

### Using Foundry (Recommended)

```bash
# Build contracts
make build

# Or directly with forge
forge build --via-ir
```

**Note:** The `--via-ir` flag is required for compilation due to contract complexity.

## Testing

### Foundry Tests

```bash
# Run all tests
make test

# Run tests with specific arguments
make test ARGS="--match-contract TestBullaInvoiceFactoring"

# Run invariant tests
make test_invariant

# Run with detailed traces
make trace

# Generate coverage report
make coverage
```

### Hardhat Tests

```bash
# Run Hardhat test suite
yarn test
```

### Test Coverage

The project includes comprehensive test coverage:

-   **Unit Tests** - Individual contract functionality
-   **Integration Tests** - Cross-contract interactions
-   **Invariant Tests** - Property-based testing
-   **Access Control Tests** - Permission system validation
-   **Edge Case Tests** - Error handling and boundary conditions

## Deployment

### Environment Setup

Create a `.env` file with required environment variables:

```bash
# RPC URLs
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/your-key
POLYGON_RPC_URL=https://polygon-rpc.com
MAINNET_RPC_URL=https://mainnet.infura.io/v3/your-key

# Private keys (use a dedicated deployment wallet)
PRIVATE_KEY=your-private-key

# Etherscan API keys for verification
ETHERSCAN_API_KEY=your-etherscan-key
POLYGONSCAN_API_KEY=your-polygonscan-key
```

### Deploy to Networks

```bash
# Deploy to Sepolia testnet
yarn deploy:sepolia

# Deploy to Polygon
yarn deploy:polygon

# Deploy to Mainnet
yarn deploy:mainnet
```

### Deploy Additional Components

```bash
# Deploy automation checker
yarn deploy:automation:sepolia

# Deploy fund manager
yarn deploy:fundmanager:sepolia

# Apply permissions
yarn apply-permissions:sepolia
```

### Contract Verification

```bash
# Verify on Sepolia
yarn verify:sepolia

# Verify on Polygon
yarn verify:polygon

# Verify on Mainnet
yarn verify:mainnet
```

## Network Deployments

The contracts are deployed on multiple networks:

-   **Mainnet** - Production deployments
-   **Polygon** - Production deployments
-   **Sepolia** - Testnet deployments

Deployment addresses and ABIs are stored in the `deployments/` directory.

## Security

### Audits

-   Latest audit report: `audits/report_2024_10_03.pdf`
-   Audit scope: See `audit_scope.md`

## License

This project is licensed under the BUSL 1.1 License - see the [LICENSE](LICENSE) file for details.

## Links

-   [Bulla Network](https://bulla.network)
-   [Discord](https://discord.gg/bulla)
