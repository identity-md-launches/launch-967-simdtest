# SIMDTEST / IMD launch

A complete Foundry project containing `SIMDTEST`, `SIMDTESTHook`, an optional one-shot
`SIMDTESTLaunch` bootstrap contract, a read-only hook salt miner, and local integration tests.
The launch contracts have no owner, setters, pause, blacklist, proxy, upgrade path,
`delegatecall`, or `selfdestruct`. No transactions were broadcast for this assignment.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, and
`bytecode_hash = "none"`. Dependencies are ordinary vendored source files; no package
installation, git submodule, network, environment variables, FFI, or filesystem cheatcodes
are needed for compilation or tests. The compiler must already be installed for an offline build.
Dependency commits and licenses are recorded in [DEPENDENCIES.md](DEPENDENCIES.md).

Tests deploy the actual vendored Uniswap v4 `PoolManager`, perform its real unlock/settle
flow, and install a test ERC-20 at the fixed IMD address in an isolated local EVM. They are
not mainnet fork tests. Both token orderings, all four swap modes, every launch block,
fee-growth accounting, LP collection, conservation, rounding, failed settlement,
unauthorized callbacks, wrong pools, partial fills, depleted liquidity, reentry attempts,
initial distribution, CREATE2 deployment, and tax-free transfers are covered.

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID **1** |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD, fixed in source | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Treasury, fixed in source | `0x3dD5F73dD1A4E62630fAd3909673F130aD429985` |
| Token decimals / IMD decimals | 18 / 18 |
| Pool LP fee | `12500`, or **1.25%**, static |
| Tick spacing | `60` |
| Required hook address flags | Low 14 bits must equal **`0x20cc`** |
| Enabled callbacks | `beforeInitialize`, `beforeSwap`, `afterSwap`, both swap return-delta flags |

The addresses above come from the assignment. Read-only calls to
`https://ethereum-rpc.publicnode.com` during implementation returned chain ID 1,
PoolManager code size 24,009 bytes, and IMD `symbol() = "IMD"`, `decimals() = 18`;
the reported chain tip was block 26,144,543. These separate calls were not a block-pinned
fork or an audit of IMD. The deployer must repeat identity/code checks before funding.
Constructors accept a manager argument so tests can use their own manager; they do not
enforce chain ID or authenticate an arbitrary supplied manager. Production must use the
mainnet argument above.

## Supply and allocation assumptions

`SIMDTEST()` has no arguments and creates exactly **1,000,000,000 × 10^18** minor units.
Its constructor emits the initial mint and immediately transfers **100,000,000** tokens to
`0x000000000000000000000000000000000000dEaD`; the remaining 900 million go to its deployer.
The dead address is **not** the zero address. As requested, this is a transfer to the dead
sink: `totalSupply()` remains one billion; circulating supply excludes that 100 million.
There is no mint, burn, or recovery method. The usual assumption that nobody controls the
dead address's private key applies. Transfers and allowance-based transfers have no tax.

The supplied `SIMDTESTLaunch` deploys this token in its constructor and enforces the
remaining distribution in one successful `launch` transaction:

* Exactly **800 million** tokens seed the SIMDTEST/IMD pool. A full-range position uses
  ticks `[-887220, 887220]`; any integer-rounding remainder is donated to that same pool.
* The unassigned **100 million** (10%) go to the helper's original deployer, the immutable
  `launchInitiator`. This is the explicit assumption for the brief's unassigned remainder.
* **The helper permanently locks the seed position and all fees it earns.** It has no
  removal, collection, transfer, rescue, or administrative method. This is a deliberate
  bootstrap choice, not a time lock or transferable LP NFT. Additional independent LPs
  can add/remove their own positions normally and collect their own fees.

Deploying the token alone burns 10% but does not seed a pool. Use the supplied helper to
enforce the full distribution. The helper's original deployer must be able to call
`launch` and approve/fund IMD; a generic deployment factory with no forwarding capability
is unsuitable. Failed launch attempts revert hook creation, initialization, and funding
atomically, leaving the helper retryable. Its token's constructor burn has already occurred.

## Fee definitions and accounting

If the pool initializes in block `B`, the anti-snipe rate at block `B + d` is
`max(3000 - 300*d, 0)` basis points. Offset **0** is the opening block. Offsets **0–9**
are charged; offset **10** and all later blocks have zero anti-snipe fee. Initialization
and liquidity seeding are atomic with the helper, so its fee clock cannot run before funding.

| Offset | Anti-snipe | Treasury | Aggregate hook rate |
| --- | --- | --- | --- |
| 0 | 30% | 0.5% | 30.5% |
| 1 | 27% | 0.5% | 27.5% |
| 9 | 3% | 0.5% | 3.5% |
| 10+ | 0% | 0.5% | 0.5% |

Both fees are denominated in **IMD**, regardless of token ordering or direction. No price
oracle or cross-token conversion is used. The constant treasury fee goes directly from
PoolManager to the fixed treasury via `take`. The anti-snipe component creates a
`PoolManager.donate` credit for liquidity active **after** the swap; it is never taken
into the hook, burned, or sent to the treasury by the hook. The matching returned hook
delta charges the swapper and cancels the hook's donation/take debt. The hook retains no
swap funds or ERC-6909 claims.

Fees apply only to this designated pool. The freely transferable token can be traded in
other permissionless pools or venues; this hook cannot impose fees on those venues.

V4 donation increases LP **fee growth**, not the position's liquidity units or the swap
curve's reserves. Independent in-range LPs can collect their entitlement as normal fees.
The bootstrap position's entitlement is locked under the helper policy above. Donations
are not automatic compounding. Other LPs may add liquidity just before a swap and capture
a share of its donation; this mechanism is not complete protection against JIT liquidity,
MEV, or sandwiching.

Define `r = antiSnipeBps + 50`, with all arithmetic in token minor units. For fee-base
volume `V`, `total = floor(V*r/10000)`, `treasury = floor(V*50/10000)`, and
`donation = total - treasury`. This caps the aggregate at 30.5% of the defined volume.
The residual rounding can add less than one IMD minor unit to the nominal donation.
Sub-unit fees round to zero. After block 10 donation is exactly zero, including dust.

| Swap | IMD fee base and caller behavior |
| --- | --- |
| Buy SIMDTEST, exact IMD input | `V` is the caller's total specified IMD budget. The pool swaps `V - total`; the caller pays exactly `V`. |
| Buy SIMDTEST, exact SIMDTEST output | `V` is the actual pool IMD input. Fees are added to that input; the requested SIMDTEST output is preserved. |
| Sell SIMDTEST, exact SIMDTEST input | `V` is the actual pool IMD output. Fees are deducted from it. |
| Sell SIMDTEST, exact net IMD output `N` | The hook requests gross pool output `V = floor((N-1)*10000/(10000-r)) + 1`, then deducts fees, leaving exactly `N`. |

For example, a launch-block exact-input buy with 100 IMD sends 30 IMD to donation,
0.5 IMD to treasury, and 69.5 IMD into the AMM swap. The **independent 1.25% LP fee**
applies to the AMM input under normal v4 rules. It is not included in the hook-rate table.
Uniswap's external protocol-fee governance is also outside these immutable contracts.

When IMD is the **specified** currency (exact-input buys and exact-output sells), v4
requires the specified delta before executing the swap. These modes intentionally
**revert on partial fills**, including tight price limits, instead of charging fees on
unexecuted volume. When IMD is unspecified, fees follow the executed pool delta and partial
fills work normally. A swap with a nonzero donation also reverts if it ends with no active
liquidity; there is no fallback recipient. Frontends must quote the hook's net amounts,
use suitable price limits, and enforce minimum output / maximum input on final deltas.

## Deployment workflow and responsibilities

1. Independently review these contracts and the locked-liquidity assumption before release.
   Tests are not a substitute for an adversarial review. No independent audit, Slither,
   or Mythril run is claimed here.
2. Use the pinned build settings. Verify Ethereum chain ID 1 and the manager/IMD addresses
   and IMD's standard, non-rebasing, non-taxed ERC-20 behavior. Choose the launch initiator
   deliberately: it receives the remaining 10% and has the one-time funding responsibility.
3. Deploy `SIMDTESTLaunch(IPoolManager)` with the exact mainnet manager above. This deploys
   the token and performs the immediate dead-address allocation. Record the helper and token.
4. Mine a CREATE2 salt against that **deployed helper**, its actual token, and this exact
   compiler output. `hookInitCodeHash()` and `predictHook(bytes32)` expose the inputs.
   The read-only script can be called as follows (replace the bracketed deployment/RPC inputs):

   ```sh
   forge script script/MineHook.s.sol:MineHook \
     --sig 'run(address,uint256,uint256)' <helper-address> 0 1000000 \
     --rpc-url <ethereum-mainnet-rpc>
   ```

   It does not broadcast. It returns a salt and predicted address; check the mask `0x3fff`
   gives `0x20cc`. Change `start` for a further bounded search if needed. Re-mine after any
   bytecode/constructor/deployer change. Do not deploy a hook at an arbitrary address.
5. Choose `sqrtPriceX96 = sqrt(currency1/currency0) * 2^96` with currencies sorted by address.
   Both tokens have 18 decimals. Initial price and matching IMD funding were not specified
   by the brief; they must be chosen and simulated by the launch initiator. Price must lie
   strictly inside the seed tick range. `liquidityForSeed(price)` exposes the seed liquidity;
   IMD funding is determined by that price and liquidity. Reject any economic price or
   funding amount the initiator has not reviewed.
6. Approve the helper for the reviewed IMD budget, then have its original deployer call
   `launch(sqrtPriceX96, maxImd, hookSalt)`. The helper deploys the hook, initializes its
   exact pool, adds full-range liquidity, donates token dust, settles both currencies, and
   transfers the remaining 10%. Actual IMD must not exceed `maxImd`; excess approval is not
   spent. Revoke unused approval afterward if any. A private submission can reduce launch MEV.
7. Verify deployed source/bytecode, immutable arguments, hook permission bits, pool key,
   opening block, seed liquidity, dead balance, remaining allocation, and treasury address.
   Publish the actual pool ID and addresses so users select the intended pool.

For a separate launch factory, the direct hook signature is
`SIMDTESTHook(IPoolManager manager, address token)`. Its constructor fixes the deployer as
the **one-time initializer**; only that address can initialize the exact token/IMD pool.
The token and IMD must already have code. That factory must perform the 80% seeding and
10% remaining allocation itself. The helper implements this path without embedding any
PoolManager deployment in the hook's creation code.

`beforeInitialize` validates the manager, initializer, and full pool key. A predicted pool
cannot initialize through a missing hook, unrelated pools cannot use this hook, and the
opening block cannot be reset. Initializer authority expires after that one initialization;
it cannot change fees, token, pair, treasury, permissions, or pool configuration.

After launch there are **no configuration setters or required operator transactions**.
The deployer remains responsible for source verification and accurate public deployment
details. The treasury simply receives IMD. Accidentally sent assets have no rescue path.

## Local validation

Local `forge build`, `forge test` (**65 passing tests**, with 256 cases per fuzz test),
and `forge fmt --check` passed with the pinned compiler. The tests use real CREATE2 hook
deployments and check EIP-170 runtime and EIP-3860 initcode limits. The final build sizes are:

| Contract | Runtime bytes | Initcode bytes, including constructor arguments |
| --- | ---: | ---: |
| SIMDTEST | 1,358 | 1,768 |
| SIMDTESTHook | 4,844 | 6,085 |
| SIMDTESTLaunch | 12,601 | 14,838 |

All are below 24,576 runtime / 49,152 initcode bytes. Source review and a local scan of
the compiler-generated executable runtime segments found no `DELEGATECALL` or
`SELFDESTRUCT` opcodes. The vendor checksums were also verified.

Only `src/` contracts are launch artifacts; test mocks, routers, the test PoolManager's
protocol owner, and the read-only salt miner are not privileged components of this launch.
