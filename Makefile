.PHONY: test

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

build  :; forge build --via-ir
test   :; forge test -vvv --fork-url ${SEPOLIA_RPC_URL} --via-ir
test-s   :; forge test --match-path test/foundry/TestErrorHandlingAndEdgeCases.t.sol -vv --fork-url ${SEPOLIA_RPC_URL} --via-ir
trace   :; forge test -vvvv --fork-url ${SEPOLIA_RPC_URL} --via-ir
coverage   :; forge coverage -vv --fork-url ${SEPOLIA_RPC_URL} --ir-minimum --report lcov