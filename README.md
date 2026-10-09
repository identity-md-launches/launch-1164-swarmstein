# Swarmstein (SWARMSTEIN)

A plain, fixed-supply ERC-20 for an ordinary token launch on Robinhood Chain (chain id 4663),
launched through IdentityMD's ProjectFactory as a `custom_token` launch. The name and theme are
branding only.

| Item | Value |
| --- | --- |
| Solidity contract | `SWARMSTEINToken` (`src/SWARMSTEINToken.sol`) |
| `name()` | `Swarmstein` |
| `symbol()` | `SWARMSTEIN` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 tokens = `1000000000000000000000000000` (1e27) minor units |
| Constructor arguments | none |
| Minting after deployment | none; `totalSupply()` is a compile-time constant |
| Owner / admin | none |
| Fees, taxes, limits | none |
| Upgradeability, proxies, `delegatecall`, `selfdestruct` | none |

## Behaviour

- The constructor mints the entire supply to `msg.sender` once and emits the EIP-20 mint
  `Transfer(0, deployer, 1e27)`. At launch `msg.sender` is the ProjectFactory.
- `transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `totalSupply` and the three
  metadata getters are standard EIP-20. Transfers move exactly the requested amount.
- Transfers to or from the zero address revert; approvals to or from the zero address revert.
  An allowance of `type(uint256).max` is treated as infinite and is not decremented.
- There is no `mint`, `burn`, `pause`, blacklist, fee setter, owner or any other privileged call.
  The contract has no `receive` or `fallback`, so it does not accept ETH.
- The contract has no imports: every byte of the deployed code comes from this one file.

## Supply distribution (done by the launch, not by this contract)

The token mints the whole 1e27 units to its deployer, the factory, and never subtracts the swarm's
share. The factory then:

1. sends 10% of the supply to the launch's MerkleDistributor (the swarm's share);
2. seeds the single-sided Uniswap v4 pool with `economics.poolBps` = 9000 (90% of the supply) via
   the PoolManager at `0x8366a39cc670b4001a1121b8f6a443a643e40951`;
3. sends any remainder to `economics.remainderTo` = `0x000000000000000000000000000000000000dead`.

Nothing in this repository is allocated, reserved or sent any of the supply.

## Pool and economics (`launch.json`)

| Field | Value |
| --- | --- |
| `pool.pairedCurrency` | IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals) |
| `pool.fee` | 12500 (1.25%, the launch policy's fee) |
| `pool.tickSpacing` | 60 |
| `pool.initialPrice` | `125270724187523965593206900` (provenance only, SWARMSTEIN as currency0) |
| `economics.poolBps` | 9000 |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2500 IMD opening market cap) |
| `economics.remainderTo` | `0x000000000000000000000000000000000000dead` |

`pool.initialPrice` is recorded for provenance. The deployer derives the real opening
sqrtPriceX96 from `initialMarketCapWei`, the token supply and the deployed currency order,
which depends on the token's address and is unknown before launch.

## Build

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, the optimizer (200 runs) and
`bytecode_hash = "none"` with CBOR metadata disabled, so the deployed bytes are reproducible and
contain no metadata hash. `ffi` is off and there are no filesystem permissions.

```sh
forge build
forge test
forge fmt --check
```

`lib/forge-std` is vendored as ordinary files (test dependency only; the token imports nothing).
The verifier runs with no network, so no dependency is fetched at build time.

## Tests

`test/SWARMSTEINToken.t.sol` holds the smoke tests this assignment asked for: deployment and
metadata, the whole supply minted to the deployer, exact-amount transfers (no fee or tax),
whole-balance and zero transfers (no limit), approvals and `transferFrom`, infinite allowance,
the failure paths (insufficient balance, insufficient allowance, zero addresses), that common
admin selectors do not exist, that the runtime contains no `DELEGATECALL`, `CALLCODE` or
`SELFDESTRUCT`, and that ETH is refused. Fuzz and invariant suites are deliberately not here;
a separate assignment writes the full suite.

Tests read no environment variables and do not depend on the caller address.

## Assumptions and operational responsibilities

- The launch deploys `SWARMSTEINToken` from the bytecode as built here, with no constructor
  arguments. The constructor calls no other contract, so it deploys on an empty chain.
- Chain, pair currency, pool fee, tick spacing, factory, PoolManager and the swarm's 10% are
  fixed by the launch order and policy, not by this contract or by anyone operating it.
- After launch there is nothing to configure, no key to hold and no admin to rotate: the token
  has no settable parameter. Nobody can pause, freeze, mint or seize.
- Passing tests are not a security audit. The token is a minimal self-contained ERC-20, but an
  independent adversarial review is still part of the launch process.
- This repository does not deploy, broadcast or hold keys; the launch's deployer does that.
