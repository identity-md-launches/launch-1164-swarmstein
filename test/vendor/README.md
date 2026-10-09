# Vendored test dependencies

Test-only code, committed as ordinary files so the suite builds with no network. Nothing here is
deployed; `src/SWARMSTEINToken.sol` imports nothing.

| Path | Source | Commit | Licence |
| --- | --- | --- | --- |
| `v4-core/src` | https://github.com/Uniswap/v4-core, tag `v4.0.0` | `e50237c43811bd9b526eff40f26772152a42daba` | `v4-core/licenses` (BUSL-1.1 for the core, MIT for the rest, as upstream) |
| `solmate/src/auth/Owned.sol` | https://github.com/transmissions11/solmate | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | `solmate/LICENSE` (AGPL-3.0) |

Changes from upstream:

- `v4-core/src/test/` is omitted (it imports forge-std, OpenZeppelin and solmate mocks that are
  not needed here).
- `v4-core/src/ProtocolFees.sol` imports `Owned` by relative path
  (`../../solmate/src/auth/Owned.sol`) instead of the `solmate/` remapping, because
  `remappings.txt` is protected in this project.

The tests build the real `PoolManager` in place at the Robinhood Chain address
`0x8366a39cc670b4001a1121b8f6a443a643e40951` (v4's manager records the address it was constructed
at), so the swap tests exercise Uniswap v4's actual settlement and fee accounting offline.
