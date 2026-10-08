# Vendored dependencies

All dependency files are ordinary files, with no submodules or install step.

| Dependency | Exact revision | Included files | License |
| --- | --- | --- | --- |
| [Uniswap v4-core](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba) | `e50237c43811bd9b526eff40f26772152a42daba` (`v4.0.0`) | `src/` except upstream `src/test/`, plus `licenses/` | MIT / BUSL-1.1, per source headers |
| [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pinned revision) | `src/auth/Owned.sol`, `LICENSE` | AGPL-3.0 license file; Owned.sol SPDX AGPL-3.0-only |

The v4-core source and Solmate file are unmodified upstream copies. Source checksums are
listed in `lib/SHA256SUMS` (verify using `sha256sum -c lib/SHA256SUMS` from the repository root).
Only the local test PoolManager uses Solmate's protocol-owner implementation. No launch
contract inherits it. The contracts in `src/` and local tests/scripts have MIT SPDX headers.
The imported assignment references are inputs only and are not build dependencies.
