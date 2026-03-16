# Project: Factoring Contracts

## Build & Test

- Always use `--via-ir` flag when running forge commands (build, test, etc.)
- Use `make test` / `make build` which set `FOUNDRY_PROFILE=test` automatically (lower optimizer_runs to avoid "Tag too large" errors)
- Default profile uses `optimizer_runs = 200` for production deployments
- Windows environment: do not use `VAR=value command` syntax in shell commands — it's not cross-platform
