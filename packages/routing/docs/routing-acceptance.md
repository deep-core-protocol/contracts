# `packages/routing` — acceptance, 2026-09-24

`DeepCoreFillRouter` + `DeepCoreFillExecutor`. **Not deployed anywhere.**

This package took the full contract acceptance bar rather than a lighter one, because CLAUDE.md
says it must: *"A router that takes a fee sits in the SWAP PATH and handles user funds — it gets the
same acceptance bar as the contracts, not a lighter one."* It was the only DeepCore contract package
that had never been Slither'd and had never had a live-transaction bar.

| Bar | Result |
|---|---|
| 1. Slither on the whole package | 0.11.6, 11 contracts / 102 detectors / 14 results. **No true positive.** |
| 2. ≥2 live transactions per external function | **94 transactions, ~55 view reads, 0 unexpected outcomes** across four runs |
| 3. Funds can never be stuck | answered below, and the native path proved on chain |
| 4. No backdoors | answered below |
| Tests | **63/63 under BOTH profiles** (default cancun/EIP-1153 and legacy shanghai/storage) |

Chain for the live bar: a plain anvil **pinned to chain id 8453**, so any Base-only branch is taken
rather than skipped. Logs: session scratchpad `routing-bar{,2,3}.log`; harnesses `routing-bar{,2,3,4}.mjs`.

---

## 1. Slither — no true positives

One Medium, the rest Informational.

| Detector | Where | Verdict |
|---|---|---|
| `dangerous-strict-equalities` | `DeepCoreFillExecutor.sweepStray` — `amount == 0` | **False positive.** It is a "nothing to sweep" sentinel on a balance read in the statement immediately above it (`address(this).balance` / `balanceOf`), not a comparison that governs value flow, and nothing accrues or rounds between the two lines. Same intentional pattern already triaged on `DeepCorePadFactory` and the utilities. |
| `low-level-calls` | the venue call, and native sends | By design. The venue call is the whole point of the contract, and its revert is deliberately re-raised (`_bubble`) so a user sees why their route failed. |
| `assembly-usage` | `_bubble` | One `revert(add(ret,0x20), mload(ret))`, marked `memory-safe`. |
| `incorrect-versions-of-solidity`, `different-pragma-directives`, `naming-conventions` | package-wide | Informational; the pragma spread comes from the shared OpenZeppelin tree. |

---

## 2. Live-transaction bar — 94 transactions, 0 unexpected

### Part 1 (43 tx, 37 views) — the money path and the owner surface

- A real token→token fill: the trader paid, the venue filled, the trader received output, and a fee
  accrued to the router.
- **The exempt venue was charged exactly 0.** This is the "0 on a DeepCore pool" promise from the
  owner's routing decision, checked as a wei-exact balance delta rather than as a quote.
- Four constructor refusals: fee above its own cap, cap above the compile-time ceiling, zero fee
  recipient, notice below the minimum.
- Eight `fill` refusals, each with its own error: `DeadlinePassed`, zero recipient, zero amount,
  identical currencies, `FeeAboveQuoted`, `InsufficientOutput`, target = the router, target with no
  code.
- Owner surface: `setFeeBps` refused to a stranger (`OwnableUnauthorizedAccount`) and above the cap
  (`FeeAboveCap`); `cancelPendingFee`; `exemptVenue` refused to a stranger; `renounceOwnership`
  reverts `RenounceDisabled` for **both** the owner and a stranger.
- `flushFees` called by a **stranger** moved the entire accrued fee to the immutable recipient and
  left the router at 0; a second call reverted `NothingToFlush`.
- `execute()` called directly by a stranger reverted `NotRouter`.
- `sweepStray` by a **stranger**, for an ERC-20 and for native, paid the whole balance to the
  immutable recipient; empty calls reverted `NothingToSweep`.

### Part 2 (25 tx, 8 views) — the fee notice, actually expiring

Part 1 proved an increase *waits*; it cancelled before the notice elapsed, so "it eventually
applies" was untested. Both halves matter — a notice that never expires is a fee that can never
rise, and one that expires early is the governance promise broken.

```
schedule 10 -> 50 bps      feeBps = 10   pendingFee = (50, <ts>)
+ (notice − 120s)          feeBps = 10   ← still 10 two minutes early
+ 300s                     feeBps = 50   ← applied by TIME ALONE, no transaction
set 50 -> 10 (decrease)    feeBps = 10   ← immediate
```

Delay sits on escalation and never on reduction, which is the house rule.

Also here: native input via `wrapInput` (a real fill, gas 267,234), `WrapMismatch` when `wrapInput`
is set on a non-native input, `UnexpectedValue` when native is declared but no value is sent, a
**fee-on-transfer input token refused** rather than silently mis-quoted, and `NativeTransferFailed`
when the recipient refuses native — a payout that cannot land reverts rather than stranding.

### Part 3 (21 tx, 5 views) — reentrancy, all four modes

A venue is arbitrary code the router calls **while the executor holds the fill's funds**. This is
the most dangerous shape in the package, so every mode of `ReentrantVenue` was driven properly via
`setMode` + `attack`:

| Mode | What it tries | Refused with |
|---|---|---|
| `FillAgain` | re-enter `router.fill()` mid-fill | `ReentrancyGuardReentrantCall` |
| `FlushFees` | divert the accrued fee mid-fill | `ReentrancyGuardReentrantCall` |
| `ExecuteDirectly` | call `executor.execute()` mid-fill | `NotRouter` — refused by the `onlyRouter` gate before the guard was even reached |
| `SweepStray` | take the funds in flight | `ReentrancyGuardReentrantCall` |

Then: a normal fill through a benign venue still worked afterwards (the guard does not leave the
router unusable), and **the executor's IN, OUT and native balances were all 0** at the end — a fill
ends it empty.

### Part 4 (5 tx) — native cannot strand in the router

`DeepCoreFillRouter` has a `receive()`, so rule 3 demands a path out. 3 native forced in through it,
`flushFees(NATIVE)` by a **stranger** moved all 3 to the immutable recipient, router left at 0, and
a second call reverted `NothingToFlush`.

---

## 3. Funds path — what can reach these contracts, and how every unit leaves

**`DeepCoreFillRouter`**

| In | Out |
|---|---|
| ERC-20 pulled from the payer by `fill` (measured, not assumed) | to the executor for the venue; output to `recipient`; refund to the payer |
| native sent with `fill` | same |
| native forced in through `receive()` | `flushFees(NATIVE)` — permissionless, immutable recipient only |
| the accrued fee, which simply stays after a fill | `flushFees(currency)` — permissionless, immutable recipient only |

**`DeepCoreFillExecutor`**

| In | Out |
|---|---|
| whatever the router forwards for a fill | `_sweepTo` both sides unconditionally at the end of `execute`, back to the router |
| a venue's output arriving as native (`receive()`) | same, or `sweepStray` |
| anything misdirected or donated | `sweepStray(currency)` — permissionless, immutable recipient only |

**Nothing is ever owed to a user from either resting balance**, which is what makes a permissionless
whole-balance sweep safe: a fill empties the executor before it returns (proved on chain in part 3),
and the router's resting balance is fee plus strays. Verified: no `delegatecall`, no `selfdestruct`.

Unsupported, and refused rather than mis-handled: **fee-on-transfer input tokens**.

## 4. Backdoors — what the owner can and cannot do

**Can:** `setFeeBps` inside the immutable `maxFeeBps` (increase only after the immutable notice,
decrease immediate, never retroactive to a quote already given); `cancelPendingFee`; `exemptVenue`
(one-way — an exemption can be added, never removed, so it can only ever make the protocol take
*less*); two-step ownership transfer.

**Cannot:** change `protocolFeeRecipient`, `EXECUTOR`, `WNATIVE`, `maxFeeBps` or `feeNoticeSeconds`
— all five are immutable, and the executor is constructed by the router's own constructor so it can
never be re-pointed. Cannot exceed `ABSOLUTE_MAX_FEE_BPS = 100` (1%), a compile-time ceiling above
the immutable cap. Cannot touch a user's funds or allowances, cannot decide or block a route, cannot
pause, cannot upgrade, cannot renounce (`RenounceDisabled`, proved for owner and stranger).

`flushFees` and `sweepStray` are **permissionless and pay only the immutable recipient**, so neither
is a key-controlled path to value.

---

## Remaining risks and what is NOT covered

1. **Not deployed anywhere.** These figures are from a local anvil.
2. ~~No real venue has ever been filled against.~~ **CLOSED 2026-09-24 — see §8 below.**
3. **Gas figures do not transfer to a release build.** Measured from this package's own artifacts
   under the default profile.
4. **Fee-on-transfer inputs are unsupported** by design, and refused.
5. The **exact-output hazard** CLAUDE.md flags for this feature ("the fee must never turn an
   exact-output swap into a worse fill than quoted") is structurally avoided because the fee is
   charged on the *input* side, on `spent` — but no exact-output route has been run end to end,
   because that is a router-client concern and no client exists yet.
6. **A mutation test has not been run** against the new guards.

---

## 8. The real-venue fill — 2026-09-24, Base mainnet fork

Closes residual 1. Every earlier fill in this document went through `MockVenue`, a stub that
behaves however the test tells it to. This is the contract CLAUDE.md singles out as sitting in the
**swap path holding user funds**, so "accepted against a mock" was never the same claim as "the
integration works".

**Setup.** `anvil --fork-url <base> --fork-block-number 51759885 --chain-id 8453`. Real Base state
throughout: the previous protocol's governance Safe (threshold 3, read through the fork; its address is not reproduced here), CreateX, WETH9
`0x4200…0006`, USDC `0x8335…2913`, and Uniswap v3 `SwapRouter02`
`0x2626664c2603336E57B271c5C0b26F421741e481`. Router deployed with owner AND
`protocolFeeRecipient` = the real Safe, `feeBps` 10, cap 50, notice 604800, no exempt venue.
Read back from the chain, not from the deploy log: every one of those, plus
`EXECUTOR().ROUTER()` == the router and `renounceOwnership()` reverting.

**⚠ A trap worth keeping: the anvil dev accounts carry EIP-7702 delegation code on BASE too.**
Account 0 read `0xef0100…`, i.e. a smart account, not an EOA. CLAUDE.md records this for Robinhood
(4663) only — it is not chain-specific. Cleared with `anvil_setCode(addr, 0x)` before use; left
alone it would have silently tested a smart account's behaviour instead of a user's.

**The fill.** 1 WETH -> USDC through `DeepCoreFillRouter` into the real Uniswap v3 router, venue
calldata `exactInputSingle` with `recipient = EXECUTOR`:

| | |
|---|---|
| status / gas | **1** / 280,940 |
| USDC out | **2,672,282,467** (2,672.28 USDC for 1 WETH — a market rate, not a mock's invention) |
| `spent` | 999,000,999,000,999,000 |
| `feeAmount` | **999,000,999,000,999** = `spent x 10 / 10_000`, exact |
| `spent + fee` | 999,999,999,999,999,999 (1e18 - 1) <= 1e18 — **the header's invariant, on real numbers**, 1 wei refunded |
| executor WETH / USDC / native after | **0 / 0 / 0** |
| executor allowance to the venue after | **0** |

Those last two rows are the point, and they are what a mock cannot establish: the executor is left
empty and un-approved after a call into a contract whose behaviour we do not control.

**The zero-on-DeepCore leg.** `exemptVenue` called BY THE REAL SAFE (impersonated) — a stranger was
refused — then the same fill again: fee delta **exactly 0**, executor again empty. So "0 on a DeepCore
pool" is demonstrated rather than asserted.

**What this does NOT prove, stated so the claim is not read wider than it is:**
- The exempt leg used the SAME third-party venue marked exempt, because **DeepCore core is not deployed
  on Base**. It proves the exemption MECHANISM, not a fill against a real DeepCore pool. Re-run that leg
  against an actual DeepCore pool once core is live there.
- Impersonating the Safe exercises the router's owner-only path, NOT the Safe's own
  `execTransaction` with three owner signatures. **G-5 is not closed by this run.**
- A fork has no real mempool, no MEV and no real gas market.
- ~~Exact-output (residual 5) is still unexercised.~~ Closed 2026-09-30, §9.

**Two errors made while running this, recorded because both produced a plausible-looking failure:**
bash **overflowed** computing `1e18 * 10 / 10000` (64-bit signed), yielding a NEGATIVE fee and a
venue call that reverted with Uniswap's `STF` — which reads exactly like a contract bug. And the
venue budget was assumed to be `amountIn - fee`; it is
`received * BPS_DENOMINATOR / (BPS_DENOMINATOR + bps)`. Compute fee arithmetic with big integers,
and read the budget out of `fill` rather than deriving it.

## 9. Exact-output against the real venue — 2026-09-30, Base mainnet fork

Closes residual 5. Fork of Base (block 51,976,572, chain id 8453); router deployed with owner and
`protocolFeeRecipient` = the real Safe, `feeBps` 15, cap 50, notice 7 days; a throwaway key derived from a
label (no anvil dev account, so no EIP-7702 code). Venue: Uniswap v3 `SwapRouter02`,
`exactOutputSingle` WETH -> USDC (0.05% pool), 1,000 USDC out, `amountInMaximum` = quote + 0.5%, and the
caller signs for `ceil(max x (10_000 + 15) / 10_000) + 1` so the router's budget covers the venue's cap.

| | ERC-20 input (WETH) | native input (`wrapInput`) |
|---|---|---|
| output to the recipient | **1,000,000,000 exactly** | **1,000,000,000 exactly** |
| `spent` | 374,231,892,246,871,344 (= the quote) | 374,242,183,755,005,395 |
| fee | 561,347,838,370,307 = `spent x 15 / 10_000` | 561,363,275,632,508 = `spent x 15 / 10_000` |
| spent + fee + refund | = the signed 376,667,206,285,667,860 | = the signed amount, exactly (refund 1,863,659,255,029,957) |
| executor after | 0 WETH / 0 USDC / 0 native, allowance 0 | the same |

Refusals, both MINED as reverts: a venue cap 1% under the quote (the venue reverts, the caller's WETH is
unchanged) and `minAmountOut` one unit above the exact output (`InsufficientOutput`).

So "the fee must never turn an exact-output swap into a worse fill than quoted" now holds on real numbers:
the output is exactly what was asked, and the total outlay never exceeds what was signed. Harness: scratchpad
`exact-output-fork.sh` (session 2026-09-30).
