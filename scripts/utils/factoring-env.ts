import { FullConfig } from '../network-config';

/**
 * Env vars read by script/DeployConfig.sol (shared by DeployBullaFactoring and PreDeployChecks).
 * Contains no private keys, so it is safe to hand to the read-only pre-deployment checks.
 */
export function buildFactoringEnv(config: FullConfig, network: string): NodeJS.ProcessEnv {
    return {
        NETWORK: network,
        BULLA_CLAIM: config.bullaClaim,
        UNDERLYING_ASSET: config.underlyingAsset,
        UNDERWRITER: config.underwriter,
        BULLA_DAO: config.bullaDao,
        PROTOCOL_FEE_BPS: config.protocolFeeBps.toString(),
        ADMIN_FEE_BPS: config.adminFeeBps.toString(),
        POOL_NAME: config.poolName,
        TARGET_YIELD_BPS: config.targetYieldBps.toString(),
        POOL_TOKEN_NAME: config.poolTokenName,
        POOL_TOKEN_SYMBOL: config.poolTokenSymbol,
        BULLA_CLAIM_INVOICE_PROVIDER_ADAPTER_ADDRESS: config.BullaClaimInvoiceProviderAdapterAddress || '',
        FACTORING_PERMISSIONS_ADDRESS: config.factoringPermissionsAddress || '',
        DEPOSIT_PERMISSIONS_ADDRESS: config.depositPermissionsAddress || '',
        REDEEM_PERMISSIONS_ADDRESS: config.redeemPermissionsAddress || '',
        BULLA_FREND_LEND_ADDRESS: config.bullaFrendLendAddress || '',
        BULLA_INVOICE_ADDRESS: config.bullaInvoiceAddress || '',
        BULLA_FACTORING_ADDRESS: config.bullaFactoringAddress || '',
        ...(config.insuranceFeeBps !== undefined && { INSURANCE_FEE_BPS: config.insuranceFeeBps.toString() }),
    };
}
