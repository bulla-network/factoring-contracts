# Project: Factoring Contracts

## Build & Test

- Always use `--via-ir` flag when running forge commands (build, test, etc.)
- Use `FOUNDRY_PROFILE=test` when building or running tests (uses lower optimizer_runs to avoid "Tag too large" errors)
- Example: `FOUNDRY_PROFILE=test forge build --via-ir`, `FOUNDRY_PROFILE=test forge test --via-ir`
- Default profile uses `optimizer_runs = 200` for production deployments
