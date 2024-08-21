### Bulla Factoring Pool Contracts

The **Bulla Factoring Pool Contracts** represent the latest advancement in the Bulla Network's ecosystem, designed to integrate seamlessly with the existing **Bulla Claim Protocol V1**. The Bulla Claim Protocol is a robust framework of smart contracts that facilitates the representation of on-chain credit relationships, such as IOUs, between parties. These claims can encapsulate various types of on-chain assets, including invoices, payments, loans, bonds, and more.

The Bulla Factoring Pool Contracts specifically enable the creation of credit pools for invoice factoring, adhering to the **ERC4626** specification. Through these contracts, invoice issuers can factor their receivables, allowing them to receive early payments in exchange for a premium. This integration not only broadens the utility of the Bulla Claim Protocol but also provides a new financial mechanism for liquidity and credit management on-chain.

# Design decisions.

For design scope for factoring contract V1 is to be permissioned and trusted.

A whitelist defines who can deposit into the pool (ensuring KYC/Compliance).
A whitelist defines who can factor invoices to get financing.

However, the logic of these is outscoped from the core contracts and called via an interface that can have a more in-depth and permissionless implementation if so desired.

The owner of the contracts is trusted.

The asset token will be USDC or another stablecoin (USDC is all forseeable use cases).

Out scoped from this audit are the Bulla Claim V1 contracts

Learn more about the Bulla Claim Contracts here: https://github.com/bulla-network/bulla-contracts

Invoices are minted by trusted operators who are allowed via a whitelist. They mint invoices to debtors, which are also trusted KYC'd.

A known risk would be that a debtor can reject an invoice (not accessible via our front-end but via etherscan).

The underwriting process happens off-chain on our servers. Any debtor can be banned if need be.

In the future, we could enforce that an invoice must have 1 wei paid on it, which makes it unrejectable in our protocol.

To future proof for new versions of Bulla Claim contracts or any other receivable contracts, we have the IInvoiceProviderAdapter interface, which decouples the pool from specific invoice contracts.

The core scope of the audit would be the BullaFactoring pool and the InvoiceProviderAdapter.

# Stakeholders:
- Invoice creditor:
    - For the time being, this is an trusted partner.
- Invoice debtor:
    - Eventually, in a world where businesses on-chain, this would be the debtor of the invoice. In our current case, this is the same trusted partner that minted the invoice. The invoice in brought on-chain, so the real payment of the invoice happens offchain, and is onramped to pay the invoice on-chain. Debtors are whitelisted in our underwriting process in our backend.
- Pool owner:
    - This is Bulla in the current use case, so completely trusted.
- Pool depositors:
    - This is also Bulla, however, in the near future, we want to expand this to be KYC'ed third parties, so trusted to an extent but still not permissionless.
- People who can factor:
    - These are whitelisted addresses, via the factoringPermissions contract.
-Applications:
    - Users will be interacting with the contracts via the Bulla dApp.

# Assumptions:
- We really on USDC mostly. We do not anticipate deploying pools with other stablecoins as the underlying asset.
- We have a backend for the underwriter process and our underwriter PK is stored in our cloud provider vault.
- We use Gelato Network to listen on ClaimPayment events in Bulla Claim Protocol to check if any active invoices are paid. If paid, it calls the `reconcileActivePaidInvoices` function which wraps up the accounting and send the kickback amount if applicable.
- The current underlying invoice provider contracts are the Bulla Claim V1 contracts and we do not anticipate any other invoice types for this audit.

# Functional requirements
- Invoices must be approved by underwriter only. 
- An invoice must be approved by underwriter before being funded.
- To Be continued.