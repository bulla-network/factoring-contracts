// Validates bulla_registry_export/pools.json and scripts/pending-pools.json against pools.schema.json and the rules
// the schema can't express. Run in CI through `make test` (DEV-2937). Exits 1 on any problem.
import { validatePoolFiles } from './utils/pools';

const errors = validatePoolFiles();
if (errors.length) {
    console.error(`❌ Invalid pool config (${errors.length}):\n  ${errors.join('\n  ')}`);
    process.exit(1);
}
console.log('✅ pools.json and pending-pools.json are valid');
