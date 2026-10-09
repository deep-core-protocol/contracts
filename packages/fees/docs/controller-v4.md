# `DeepCoreProtocolFeeControllerV4`: one controller, several kits

**INTERNAL.** Written 2026-09-28. Not deployed. Owner decision, 2026-09-28: "a controller that
recognises both: yes". V3's design (`controller-v3.md`) still holds for everything this document
does not mention; read that first.

## 1. Understanding

A pool manager has one `protocolFeeController`. V3 zeroes the core protocol fee on a pool when ONE
immutable oracle, a `LaunchpadKitV2`, says the pool is a locked launch, and it refuses the owner's
`setPoolProtocolFee` with a non-zero value on such a pool.

New launch guards are new addresses (a hook address is part of pool identity), so they come with
a new kit beside the first. With V3 bound to one kit, the other kit's launch pools lose both
properties: a new pool is born paying the policy fee, and an existing one can be charged by the
owner. V4 names a SET of kits, so both properties hold for every kit in it.

## 2. Assumptions

- Every oracle is a DeepCore kit deployment, never an adapter with a setter. The contract cannot
  check this; the deploy script and the Custody review do.
- The set is small. `MAX_LAUNCH_ORACLES` is 4.
- `policy` is the live `DeepCoreProtocolFeeControllerV2`, unchanged.

## 3. Architecture

```
protocolFeeForPool(key) = policy says 0                         ? 0
                        : any oracle_i.isLockedLaunch(key.toId()) ? 0
                        : policy.protocolFeeForPool(key)
```

| Part | V3 | V4 |
|---|---|---|
| Oracles | one immutable | one to four immutables, fixed at construction, no setter |
| Asking | one bounded staticcall | one bounded staticcall per oracle, in order, stopping at the first yes |
| Gas floor | checked once | checked before EACH call, so no oracle is starved by the ones before it |
| `launchOracle()` | returns the kit | absent on purpose: a set has no single address to return |
| Reading the set | n/a | `launchOracles()`, `launchOracleCount()`, `isLaunchOracle(address)` |
| Everything else | | the same code: `collect`, `sweep`, `setPoolProtocolFee`, `syncPoolToPolicy`, `setTreasury`, `accrued`, `rescueERC20`, two-step ownership, renounce reverts |

The constructor refuses an empty list, more than four, a zero address, an address without code,
the policy itself, a duplicate, and an address that does not answer `isLockedLaunch(0)` with one
ABI-encoded `false`.

### How a kit knows it is bound

A kit's library checks, after `initialize`, that a pool it created was born at zero when the
installed controller answers to that kit (`LaunchLegs._assertBornAtZero`).

| Kit | Asks | Under V4 |
|---|---|---|
| first kit (deployed) | `launchOracle()` | no answer, so the check does not run. V4 zeroing the pool is the protection |
| new kit | `launchOracle()`, then `isLaunchOracle(kit)` | the second call answers, so the check runs |

## 4. Roles

| Role | Holder | Can | Cannot |
|---|---|---|---|
| `owner` | the Safe | `collect`, `setTreasury`, `setPoolProtocolFee` (zero only on a launch pool), `syncPoolToPolicy`, `rescueERC20`, two-step transfer | change the oracles, charge a launch pool of any kit in the set, renounce |
| anyone | | `sweep` to the stored treasury | choose the recipient |
| each oracle | a kit | lower a pool's fee to zero | raise a fee, affect a pool it does not vouch for |

No guardian: V2's guardian still zeroes non-launch pools through `policy`.

## 5. Security analysis

| Question | Answer |
|---|---|
| Can a caller's gas limit get a launch pool charged? | No. Each call has its own floor; too little gas reverts pool creation, it never skips an oracle |
| Can a broken oracle block pool creation? | No. A revert, an out-of-gas or a malformed answer counts as "no" for that oracle only, and costs at most its stipend (50,000 gas) |
| Can one wrong entry hurt users? | No user funds. An oracle that vouched for pools it did not create would waive protocol revenue on them |
| Can the owner add a kit? | No. A new set is a new controller installed through Custody (48 h, public) |
| What can reach the contract and not leave? | Native forced in, an ERC-721 and an ERC-6909 claim. It has no `receive`, is never a recipient, and takes no part in a swap. V3 is the same. `rescueERC20` covers a misdirected ERC-20 |
| Does the oracle order matter? | For gas only |

Worst-case hot path: four oracles that each burn their stipend cost about 210,000 gas per pool
creation. Two honest kits cost about 10,000.

## 6. Tests

`packages/fees/test/`: `DeepCoreProtocolFeeControllerV4.t.sol` (68), `FeeControllerV4Live.t.sol` (14,
real CL manager), `FeeControllerV4LiveBin.t.sol` (3, real Bin manager),
`FeeControllerV4Scripts.t.sol` (29). 256 tests in the package pass under both profiles. 17 mutants
of V4, 17 killed. Runtime 6,431 bytes under both profiles.

`packages/launchpad/test/kitv2/LaunchpadKitV2BornAtZero.t.sol`: the new kit under a controller
that names it (single and set), that names another kit, that names none, that answers with a word
other than 1 or with two words, that burns the bounded gas, and under the real V4 with one kit
and with two.

## 7. Deployment

**Zero-fee hook list, added 2026-09-29.** V4 also keeps a Safe-managed list of hooks whose NEW pools
resolve to zero (checked before the oracles, one storage read): add is immediate, removal waits an
immutable notice (1 to 90 days; 7 on a production chain) and applies by time alone, cancellable
before then; while listed, `setPoolProtocolFee` refuses a non-zero fee on the hook's pools. The
policy, a launch oracle, the zero address and a hook with no code can never be listed. Both
dynamic-fee hooks are listed from the constructor. Accepted at `c6b09e59`: fees 288/288 under both
profiles, 19/19 mutants of the list killed, Slither 0.11.6 with no true positive. Not deployed
on any chain.

`script/DeployFeeControllerV4.s.sol` (label `DEEPCORE_FEE_CONTROLLER_V4_ZH`, which replaces
`DEEPCORE_FEE_CONTROLLER_V4` because the constructor changed; `LAUNCH_ORACLES=<kit>,<kit>`,
`ZERO_FEE_HOOKS=<hook>,<hook>`, `ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS`), then `script/BuildInstallFeeControllerV4.s.sol`, which prints the
custody `scheduleBatch` and stops if V4 leaves out a kit the installed controller answers to.
Order and read-backs: `ops/deploy/quote-fee-redeploy.md`.

## 8. Remaining risks

- Not yet run: Slither over the package at this source, live transactions on a running chain, a
  real kit as an oracle on a running chain, and the two scripts from `run()`.
- A first-kit launch is not checked by its own kit under V4 (section 3). If V4 were ever wrong
  about a first-kit pool, the pool would be born charged and nothing would revert.
- The oracle set cannot be shortened. A kit that is retired stays an oracle for the life of the
  controller; its pools stay at zero, which is what is wanted.
