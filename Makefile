.PHONY: test test_invariant

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

build  :; forge build --skip 'test/**' --via-ir
test   :; forge test -vv --via-ir --no-match-path "**/Invariant.t.sol" $(ARGS)
test_invariant :; forge test -vvv --via-ir --match-path "**/Invariant.t.sol" $(ARGS)
test-s   :; forge test --match-test "testFuzz_OfferLoanNeverFailsNorGeneratesKickback" -vv --via-ir
trace   :; forge test -vvvv --via-ir
coverage   :; forge coverage -vv --ir-minimum --report lcov