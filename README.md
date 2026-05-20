# Augur Lituus oracle

- Solidity `^0.8.35`
- Git submodules for dependencies
- Unit + fuzz + invariant tests included as a working reference

## Setup

```bash
git clone --recurse-submodules <repo> && cd <repo>
cp .env.example .env
forge build
forge test
```

If you forgot `--recurse-submodules` on clone:

```bash
git submodule update --init --recursive
```

## Common commands

```bash
forge build                  # compile
forge test                   # run all tests
forge test -vvv              # verbose, with traces on failure
forge coverage               # coverage report
forge fmt                    # format
forge snapshot               # gas snapshot

FOUNDRY_PROFILE=ci   forge test   # 10k fuzz runs
FOUNDRY_PROFILE=deep forge test   # 100k fuzz runs, deep invariants
```

## Deploy

```bash
# local
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# testnet / mainnet (RPC aliases defined in foundry.toml)
forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
```

## Layout

```
src/        contracts
test/
  unit/         deterministic scenarios
  fuzz/         property-based
  invariant/    stateful, via a handler
script/     deploy scripts
lib/        submodule dependencies
```
