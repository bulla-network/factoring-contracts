.PHONY: test test_invariant test_fork validate_pools

# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

# deps
update:; forge update

# Build & test
# change ETH_RPC_URL to another one (e.g., FTM_RPC_URL) for different chains
SEPOLIA_RPC_URL := ${SEPOLIA_RPC_URL}

# For deployments. Add all args without a comma
# ex: 0x316..FB5 "Name" 10
constructor-args := 

build  :; forge build --via-ir --skip test --sizes
sizes  :; forge build --via-ir --sizes
# Pool config (bulla_registry_export/pools.json) against its schema; part of `make test` so CI checks it
validate_pools :; yarn --silent validate:pools
test   : validate_pools
	forge test -vv --via-ir --no-match-path "**/Invariant.t.sol" --no-match-contract "Fork" --optimizer-runs 10 $(ARGS)
test_fork :; forge test -vv --via-ir --match-path "**/fork/**" --fork-url $(ETH_RPC_URL) --optimizer-runs 10 $(ARGS)
test_invariant :; forge test -vvv --via-ir --match-path "**/Invariant.t.sol" --optimizer-runs 10 $(ARGS)
test-s   :; forge test --match-test "testFuzz_OfferLoanNeverFailsNorGeneratesKickback" -vv --via-ir
trace   :; forge test -vvvv --via-ir
coverage   :; forge coverage -vv --ir-minimum --report lcov