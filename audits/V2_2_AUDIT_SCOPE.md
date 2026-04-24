# Bulla Factoring Contracts — V2.2 Audit Scope

**Date:** April 2026
**Repo:** `bulla-network/factoring-contracts`
**Previous audit commit:** `5438af5f5869ecdbbd464a7954a246c6e91e7a8f` (December 17, 2025)
**Current HEAD:** `fba053185d359faa20313f2e34e2e2a8741e3f6e`

## Overview

This audit covers changes made since the December 2025 audit. The core factoring flow (deposit → approve → fund → reconcile) is unchanged in structure. The primary focus of these changes is **opening pools to any user who passes KYC and agreement-signing requirements**, replacing the previous manual allowlists. We are also adding PYUSD as a supported asset alongside USDC.

The deposit permissions system is lower risk from a funds-security perspective — it gates who can deposit, not how funds flow once inside the pool.

## Supported Assets

Pools will now support **PYUSD** (PayPal USD) in addition to USDC. Auditors should verify that the contracts handle both tokens correctly, particularly around decimals (both are 6 decimals) and any transfer behavior differences.

## New Compliance Contracts

### Agreement Signature Flow

Every pool has an associated off-chain legal agreement. Before a user can deposit into a pool, they must sign the current version of that agreement. The flow is:

1. The pool owner sets a `documentVersion` for each pool via `ComplianceDepositPermissions.setPoolDocumentVersion(pool, version)`
2. A user reads and signs the agreement off-chain
3. Our backend verifies the signature and calls `AgreementSignatureRepo.recordSignature(pool, documentVersion, participant)` to record it on-chain
4. When the user attempts to deposit, `ComplianceDepositPermissions.isAllowed()` checks that `agreementSignatureRepo.hasSigned(pool, docVersion, user)` is true

The `signatureApprover` role on `AgreementSignatureRepo` is a backend hot wallet — the same pattern used for invoice approvals.

### KYC Flow

KYC verification happens off-chain via Sumsub. Once a user passes KYC:

1. Our backend calls `SumsubKycIssuer.approve(address)` to mark the wallet as KYC'd
2. `BullaKycGate` checks all registered issuers (OR logic — any issuer approving is sufficient)
3. `ComplianceDepositPermissions.isAllowed()` checks `kycGate.isAllowed(user)`

The `kycApprover` role on `SumsubKycIssuer` is a backend hot wallet.

### Sanctions Screening

`ComplianceDepositPermissions` checks the Chainalysis OFAC sanctions oracle (`ISanctionsList.isSanctioned(address)`) to reject sanctioned addresses.

### ComplianceDepositPermissions (combines all three)

> **Note to auditors:** The compliance system gates who can deposit but does not affect how funds flow once inside the pool. A bug in these contracts could allow an unauthorized user to deposit, but cannot lead to loss of funds. This is lower priority than the core factoring and insurance logic — a standard review for correctness is sufficient without deep invariant analysis.

`ComplianceDepositPermissions.isAllowed(address)` enforces AND logic:
1. Not sanctioned (Chainalysis oracle)
2. KYC'd (BullaKycGate → SumsubKycIssuer)
3. Signed current agreement version for the calling pool (AgreementSignatureRepo)

The pool contract is `msg.sender` when calling `isAllowed()`, so the contract uses `msg.sender` to look up the correct pool's document version.

All three dependencies are required (address(0) rejected in constructor and setters).

### Files

| Contract | Description |
|---|---|
| `ComplianceDepositPermissions.sol` | Combines sanctions, KYC, and agreement checks (AND logic) |
| `AgreementSignatureRepo.sol` | On-chain record of agreement signatures per pool/version/participant |
| `BullaKycGate.sol` | Aggregates multiple KYC issuers (OR logic) |
| `SumsubKycIssuer.sol` | KYC issuer backed by Sumsub, managed by backend |
| `ManualBullaKycIssuer.sol` | Manual KYC issuer for admin-managed allowlists |
| `interfaces/ISanctionsList.sol` | Chainalysis OFAC oracle interface |
| `interfaces/IBullaKycGate.sol` | KYC gate interface |
| `interfaces/IBullaKycIssuer.sol` | KYC issuer interface |
| `interfaces/IAgreementSignatureRepo.sol` | Agreement signature repo interface |

## BullaFactoring Core Changes (V2_1 → V2_2)

### Insurance Mechanism (PR #207)

Adds an insurer role and insurance fund to cover impaired invoices:
- New constructor params: `insurer`, `insuranceFeeBps`, `impairmentGrossGainBps`, `recoveryProfitRatioBps`
- Insurance premium deducted at funding time alongside other fees
- Insurer can purchase impaired invoices at a discount (`impairmentGrossGainBps`)
- On recovery of impaired invoices, proceeds split between insurance fund and investors per `recoveryProfitRatioBps`

### Protocol Fee Realized Upfront (PR #206)

Protocol fee is now deducted at funding time rather than at reconciliation. Simplifies fee accounting.

### Batch Operations (PR #210)

- `approveInvoice()` → `approveInvoices(ApproveInvoiceParams[])` — batch approve
- `fundInvoice()` → `fundInvoices(FundInvoiceParams[], address[])` — batch fund with shared receiver address array, single liquidity check, batched transfers

### EnumerableSet for Active Invoices (PR #209)

Replaced `uint256[] activeInvoices` with `EnumerableSet.UintSet` for O(1) add/remove instead of O(n) array scanning.

### Receiver Address Validation (PR #215)

`fundInvoices` now validates that non-zero receiver addresses pass `factoringPermissions.isAllowed()`. Prevents funding to unauthorized addresses.

### Pool Token Transfer Restrictions (PR #217)

Overrides ERC20 `_update()` to enforce `depositPermissions.isAllowed()` on both sender and receiver for secondary market token transfers. Mint and burn are exempt (already gated by deposit/withdraw flows).

### ~~Loan Interest Rate Fix (PR #203)~~ — Superseded

This fix corrected APR calculation for loan requests. The entire loan offer system has since been removed (PR #224), making this change moot.

### Impairment Accounting Fix (PR #223)

Fixes two accounting bugs that silently leaked value on invoice impairment:

1. **Spread accrued at impairment was discarded:** `impairInvoice` only extracted `adminFeeOwed` from `FeeCalculations.calculateFees`, discarding the `spreadAmount`. In normal reconciliation, `incrementProfitAndFeeBalances` credits `trueAdminFee + trueSpreadAmount` to `adminFeeBalance` — impairment now does the same. The pool owner now correctly receives spread accrued on impaired invoices (previously this was an implicit LP windfall).

2. **Pool-owned withheld fees weren't tracked:** At funding, target `interest + admin + spread` is withheld as pool cash. On impairment, `removeActivePaidInvoice` decrements `withheldFees` accounting but the cash silently flowed into LP capital without being explicitly credited to `paidInvoicesGain`. Now it's explicit. The withheld target fees are visible as LP yield in `paidInvoicesGain` (previously they dissolved into free capital).

Also renamed `managerFeesOwed` → `ownerFeesOwed` in `calculateFees` return values for clarity since this includes both admin fees and spread.

**Files changed:** `BullaFactoring.sol`, `FeeCalculations.sol`, `IBullaFactoring.sol`

### Impairment Capital Account Fix (PR #229)

Fixes incorrect capital account and price-per-share calculations after invoice impairment. Previously, impairment incorrectly increased `paidInvoicesGain` (which inflated the capital account), when it should have recognized a loss. This PR restructures impairment accounting:

1. **New `impairmentLosses` state variable:** Tracks accumulated principal losses from impaired invoices. `calculateCapitalAccount()` now subtracts `impairmentLosses`, so the capital account correctly decreases after impairment.

2. **Combined fee deduction from gross LP credit:** Insurance payout (`impairmentGrossGain`) and pool-owned withheld fees (`poolOwnedWithheld`) are now combined into a single `grossLPCredit` pool before deducting accrued admin + spread fees. Previously, fees were only deducted from the insurance payout, which could produce incorrect results when fees exceeded insurance coverage.

3. **Principal loss uses `paymentsSinceFunding`:** The loss calculation now uses `currentPaidAmount - initialPaidAmount` (payments since funding) instead of raw `currentPaidAmount`, so pre-funding payments don't inflate recovery figures. Formula: `principalLoss = max(0, fundedAmountNet - lpCredit - paymentsSinceFunding)`.

4. **`paidInvoicesGain` no longer touched at impairment:** This field now only tracks realised interest (from reconciliation and recovery profit splits), not impairment accounting.

5. **Loss reversal on recovery:** When an impaired invoice is fully repaid, `impairmentLosses` is decremented by the original `principalLoss`, correctly reversing the loss recognition.

6. **Removed `impairmentNetGain`:** This return value from `previewImpair()` and the `InvoiceImpaired` event is no longer meaningful with the combined-pool approach. Replaced in the event with `feesCharged` and `principalLoss` for better transparency.

7. **`ImpairmentInfo` struct extended:** Added `principalLoss` field to track the loss per invoice for accurate reversal on recovery.

**Files changed:** `BullaFactoring.sol`, `IBullaFactoring.sol`

### Removal of Tap Credit / Loan Offers (PR #224)

Removes all loan offer functionality from BullaFactoringV2_2 to reduce contract bytecode below the EIP-170 24,576-byte limit. Tap Credit (the ability for pools to create loan offers via BullaFrendLend) is removed entirely and may be re-introduced as a separate contract in the future.

**Removed functions:**
- `offerLoan()` — create a loan offer through BullaFrendLend
- `onLoanOfferAccepted()` — callback when a borrower accepts a loan offer
- `removePendingLoanOffer()` — cancel a pending loan offer
- `clearStalePendingLoanOffers()` — batch clean-up of expired offers

**Removed state:**
- `bullaFrendLend` — immutable reference to the BullaFrendLend contract
- `pendingLoanOffers` mapping and `pendingLoanOfferIds` array
- All loan-offer-specific errors and events

**Contract size:** 26,773 → 23,500 bytes (1,076-byte margin under EIP-170 limit)

**Files changed:** `BullaFactoring.sol`, `IBullaFactoring.sol`

**Adapter changes (`BullaClaimV2InvoiceProviderAdapterV2.sol`):** Added `getImpairTarget(uint256 invoiceId)` function, which returns the correct contract address and function selector for impairing an invoice based on its controller type (BullaClaimV2, BullaFrendLend, or BullaInvoice). The existing FrendLend code paths remain — FrendLend invoices can still be factored via the `fundInvoices` flow.

## Out of Scope

- `BullaFactoringFactoryV2_1.sol` and `PermissionsFactory.sol` (factory/deployment contracts)
- Deploy scripts and TypeScript tooling
- Existing core flow (deposit/withdraw/redeem) — unchanged since last audit
