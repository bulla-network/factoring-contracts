# Bulla Factoring Pool Contracts V1

## Overview

The Bulla Factoring contracts specifically enable the creation of credit pools for invoice factoring, adhering to the **ERC4626** specification. Through these contracts, invoice issuers can factor their receivables, allowing them to receive early payments in exchange for a premium. This integration not only broadens the utility of the Bulla Claim Protocol but also provides a new financial mechanism for liquidity and credit management on-chain.

## Usage

To install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
```

This will download foundryup. To start Foundry, run:

```bash
foundryup -C 6b07c77eb1c1d1c4b56ffa7f79240254b73236d2
```

Repo also uses hardhat for deployment, to install dependencies:

```bash
yarn install
```

## Development

### Contracts Build

🚨 Note 🚨: Forge v0.2.0 is required to build the contracts. Using `foundryup -C 6b07c77eb1c1d1c4b56ffa7f79240254b73236d2` will install 0.2.0.

```bash
forge build --via-ir
```

### Deployment

```bash
yarn deploy:NETWORK # see package.json
```

### Tests

Create an `.env` file using the `.env.example` file as a template.

Invoke the following to run test scenarios located in `./test/foundry`, forking Sepolia network:

```bash
  make test
```

## 🔒 Security Contacts 🔒

-   mike@bulla.network
-   jeremy@bulla.network

## License

(c) 2024 Arkitoken, LLC

The Bulla Factoring Pool contracts code is licensed under Business Source License 1.1 (see the file `LICENSE`).
