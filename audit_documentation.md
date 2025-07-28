### Bulla Factoring Pool Contracts

The **Bulla Factoring Pool Contracts** represent the latest advancement in the Bulla Network's ecosystem, designed to integrate seamlessly with the new version of the **Bulla Claim Protocol**. The Bulla Claim Protocol V2 is a robust framework of smart contracts that facilitates the representation of on-chain credit relationships, such as IOUs (a signed document acknowledging a debt), between parties. These claims can encapsulate various types of on-chain assets, including invoices, payments, loans, bonds and more.

The Bulla Factoring Pool Contracts specifically enable the creation of credit pools for invoice factoring, adhering to the **ERC4626** specification. Through these contracts, invoice issuers can factor their receivables, allowing them to receive early payments in exchange for a premium. This integration not only broadens the utility of the Bulla Claim Protocol but also provides a new financial mechanism for liquidity and credit management on-chain.

The second version of the factoring pool allows for queueing redemptions and automatic reconciliation of the accounting before critical liquidity moving operations.

# Design decisions.

The design scope for factoring contract V2 is to be permissioned and trusted.

A whitelist defines who can deposit into the pool (ensuring KYC/Compliance).
A whitelist defines who can factor invoices to get financing.

However, the logic of these is outscoped from the core contracts and called via an interface that can have a more in-depth and permissionless implementation if so desired.

The owner of the contracts is trusted.

The underwriter is trusted.

The asset token will be USDC most of the time, but we would like to make sure it works other leading stablecoins (i.e. USDT) and specifically a stablecoin called WYST (sepolia address: 0x3894374b3ffd1DB45b760dD094963Dd1167e5568)

Learn more about the Bulla Claim Contracts here: https://github.com/bulla-network/bulla-contracts-V2

Invoices are minted by trusted operators who are allowed via a whitelist. They mint invoices to debtors, which are also trusted KYC'd.

A known risk would be that a debtor can reject an invoice (not accessible via our front-end but via etherscan).

The underwriting process happens off-chain on our servers. Any debtor can be banned if need be.

In the future, we could enforce that an invoice must have 1 wei paid on it, which makes it unrejectable in our protocol.

To future proof for new versions of Bulla Claim contracts or any other receivable contracts, we have the IInvoiceProviderAdapter interface, which decouples the pool from specific invoice contracts.

The core scope of the audit would be the BullaFactoring pool and the InvoiceProviderAdapter.

# Stakeholders:

-   Invoice creditor:
    -   For the time being, this is an trusted partner.
-   Invoice debtor:
    -   Eventually, in a world where businesses on-chain, this would be the debtor of the invoice. In our current case, this is the same trusted partner that minted the invoice. The invoice in brought on-chain, so the real payment of the invoice happens offchain, and is onramped to pay the invoice on-chain. Debtors are whitelisted in our underwriting process in our backend.
-   Pool owner:
    -   Some pools are owned by Bulla, others can be owned by Bulla's partners. Not completely trusted but mostly. It would be important to know what the risks could be.
-   Pool depositors:
    -   This is also Bulla, however, in the near future, we want to expand this to be KYC'ed third parties, so trusted to an extent but still not permissionless.
-   People who can factor: - These are whitelisted addresses, via the FactoringPermissions contract.
    -Applications: - Users will be interacting with the contracts via the Bulla dApp.

# Assumptions:

-   We have a backend for the underwriter process and our underwriter PK is stored in our cloud provider vault.
-   We use Gelato Network to listen on ClaimPayment events in Bulla Claim Protocol to check if any active invoices are paid (via the viewPoolStatus function). If paid, it calls the `reconcileActivePaidInvoices` function which wraps up the accounting and send the kickback amount if applicable. In V2, we basically won't need this function because it can be performed on redeems, deposits, invoice funding, etc, etc.
-   The current underlying invoice provider contracts are the Bulla Claim V2 contracts and we do not anticipate any other invoice types for this audit.

# Functional requirements

-   deposit

    -   deposits funds into the pool in exchange for pool shares
    -   must be allowed via depositPermissions
    -   gets the equivalent amount of shares per the capital account / total number of shares
    -   the accrued interest of active invoices is added to the capital account for deposits, but not for redemptions. So this interest is priced in to deposits, but not realized until invoices are paid. This is to prevent gamification.
    -   Should process the redemption queue before and after depositing the funds, due to accrued interest.

-   redeem

    -   redeem shares from the pool in exchange for the underlying token that was deposited.
    -   must be allowed in redemptionPermissions
    -   capital that is deployed (via funding invoices) and fees are considered removed liquidity from the pool, therefore there is a cap of shares that can be redeemed

-   redeemAndOrQueue

    -   same as redeem, but will not fail if no liquidity. Instead, it queues for the amount remaining in the RedemptionQueue.

-   approveInvoice

    -   an underwriter must approve an invoice to be funded and assigned it an interest rate per annum and a max upfront % it can borrow upfront
    -   approval is only valid for a certain amount of time.

-   fundInvoice

    -   Prior to being funded extra checks occur in the pool

        -   Factorer must be permitted by factoringPermissions
        -   Invoice must be approved by underwriter before being funded.
        -   Upfront percentage must be lower or equal to permitted percentage assigned by underwriter
        -   Underwriter approval lasts for an hour max
        -   Invoice must not be canceled (rejected or rescinded)
        -   paid amount on the invoice must equal to its paid amount at the time of underwriter approval
        -   creditor must be the same creditor as at the time of approval
        -   Invoice must not be paid off at the time of approval

    -   if approved, funds are send to the creditor and the invoice is transfered to the pool (becoming the new creditor)
        -   an admin fee (% of invoice value), an interest fee (% of invoice value) and a protocol fee (% of invoice value) are withheld prior to sending out the funding.

-   unfactor invoice

    -   an invoice can be unfactored by the original creditor to remove it from the pool
    -   the original creditor must pay back the principal amount + any fees accrued
    -   the invoice is transfered back to the original creditor

-   impair invoice

    -   after the due date has past + a defined grace period, the fund may decide to impair an invoice, thereby realizing a loss on it
    -   if an impaired invoice gets repaid, it behaves as if it was simply a late invoice
    -   we are aware of a risk that if an impaired invoice gets repaid when there are no longer any depositors in the pool, the funds from the invoice will essentially be lost. A workaround would be to leave 1 wei in the pool.

-   reconcile active paid invoices

    -   In order to update the pnl and other balances upon paid invoices, a Gelato Network function is executed on every ClaimPayment event (from Bulla Claim event)
    -   paid invoices are marked as such, balances are incremented, tax is incremented
    -   if upfront % was less than 100% and there is a leftover amount after fees, the amount is kickedback to the original creditor

-   processing redemption queue

    -   when the redemption queue gets processed (when invoices are reconciled mostly but also on deposit), addresses in the queue get redeemed at the current redemption price.
    -   if the user does not have the balance of tokens anymore, they get kicked out of the queue

-   offer loan

    -   instead of creating an invoice and then factoring it, users can now directly ask for a loan
    -   this avoids an unnecessary step, and also can allow for batching invoices together.
    -   it uses our BullaFrendLend V2 protocol, with a callback after the user has accepted (loans are accepted directly on the FrendLend contract as opposed to call the BullaFactoringV2 contract)

-   spread
    -   the underwriter can now add a spread to an invoice, which would be a % of invoice value that accrues to the pool owner, as opposed to accruing to the pool investors.

# Non functional requirements

-   Security of funds
