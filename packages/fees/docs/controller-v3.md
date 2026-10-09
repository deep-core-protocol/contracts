# DeepCoreProtocolFeeControllerV3: zero core fee on locked kit launches

Status: design of record for `src/DeepCoreProtocolFeeControllerV3.sol`. Written before the code.
Numbers and decisions come from CLAUDE.md "Kit fees: decided by the owner" and "Kit v2
decisions, 2026-09-14" item 2. Where this file and CLAUDE.md disagree, CLAUDE.md wins.

---

## 1. Understanding: what core actually does

Read from `packages/core/src`, not from memory.

| Question | Answer | Where |
|---|---|---|
| When is the protocol fee read? | **Once, inside `initialize`**, via `_fetchProtocolFee(key)`. It is stamped into `slot0` and never re-read. | `CLPoolManager.sol:111-115`, `BinPoolManager.sol:117-121`, `ProtocolFees.sol:46` |
| Before or after the hook? | **After** `beforeInitialize`, before `afterInitialize`. | same lines |
| How is it called? | `staticcall(gas(), controller, ...)` copying at most 32 bytes. Revert, or a return that is not exactly 32 bytes, **reverts `initialize`**. A value above the cap reverts `ProtocolFeeTooLarge`. | `ProtocolFees.sol:53-76` |
| Can it change later? | Only through `ProtocolFees.setProtocolFee(key, fee)`, gated `msg.sender == protocolFeeController`, validated against the cap, and only on an initialized pool (`CLPool.setProtocolFee` -> `checkPoolInitialized`). There is no `updateDynamicProtocolFee`; `updateDynamicLPFee` is the LP fee and is hook-only. | `ProtocolFees.sol:34`, `CLPool.sol:480` |
| What does swapping the controller do? | `setProtocolFeeController` only overwrites the pointer. **No pool's stamped fee changes.** It is `onlyOwner` on the manager, whose owner is the `*PoolManagerOwner` wrapper, where it is again `onlyOwner`. | `ProtocolFees.sol:80`, `CLPoolManagerOwner.sol:42` |
| What happens to fees accrued under the old controller? | `protocolFeesAccrued[currency]` is plain storage on the manager, and `collectProtocolFees` checks the caller **at collection time**. After the swap the new controller can collect everything accrued under V2; V2 can no longer collect anything (`InvalidCaller`). | `ProtocolFees.sol:19,85-95` |

Consequence: the "zero for locked launches" decision has to be made **at `initialize`**, or it
costs a controller-gated `setProtocolFee` per pool, which is exactly the per-pool Safe
transaction this contract exists to remove.

---

## 2. The rule

```
protocolFeeForPool(key) =
    0                                   if launchOracle.isLockedLaunch(key.toId()) answers exactly true
    V2.protocolFeeForPool(key)          otherwise
```

where `launchOracle` is an **immutable** address that in production MUST be the LaunchpadKit v2
deployment itself, and `V2` is the chain's installed `DeepCoreProtocolFeeControllerV2`
(deployed by `script/DeployFeeControllerV2Chain.s.sol`), also immutable.

### 2.1 Source of truth: (c), bound to the kit. Not (a).

**(a) `DeepCoreLaunchRegistry` + `DeepCoreLPLocker`. Rejected. It cannot work, and it is not trustworthy
enough if it could.**

1. *Timing, fatal.* The registry records a launch "proven against the pool": `registerLaunch`
   reads the pool back out of a Vault-registered manager, so the record can only exist **after**
   `initialize`. The locker's record is written in `onERC721Received`, which needs a minted
   position, which needs an initialized pool. At the one moment the fee is read, neither answer
   can be true. The fee would be stamped from "not a launch" every time.
2. *Mutable by people who are not the fee's owner.* A curator can clear a launch's attribution
   (`LaunchAttributionCleared`) and `registerLaunch` is permissionless for `Claimed` records. A
   fee predicate must not move with registry curation.
3. *"Has a lock" is spoofable.* The locker is deliberately not kit-specific (any holder may lock
   any CL position, including a v1 position). An attacker creates their own pool, locks 1 wei of
   liquidity with the minimum 20% protocol share, and would qualify for a zero core fee on all of
   that pool's real volume. The locker proves "some liquidity is locked", not "this pool is a
   locked launch".

**(b) An immutable kit address whose launch record answers.** Correct in substance: only the kit
knows, before `initialize`, that the pool it is about to create will be locked in the same
transaction or not exist at all.

**(c) An immutable `ILockedLaunchOracle`.** Chosen, as the *shape* of (b). The controller depends
on one selector, `isLockedLaunch(bytes32)` (`0x91bfe5c1`), not on `LaunchpadKit`'s storage layout
or its import graph, both of which are being rewritten right now. The interface file is MIT and
imports nothing, so the kit (GPL) and the SDK (MIT) can both use it.

Binding rule, enforced in the deploy script: `launchOracle` is the kit v2 contract itself. An
adapter contract with a setter in front of the kit would turn an immutable trust anchor into a
mutable one, and whoever held that setter could zero any pool. If the kit is ever replaced, the
controller is replaced with it, through the same Custody operation as this one.

### 2.2 Why the kit's word at `initialize` is enough

The kit's answer at `initialize` is a promise about the future of the same transaction: "this
pool's seeded position will be in the locker before this call returns". It is sound because
`createLaunch` is atomic: the flag write, `initialize`, mint, lock and the lock read-back happen
in one call with no `try/catch`. If the lock fails, the transaction reverts, taking the flag **and
the pool** with it. There is no reachable state in which a pool exists with the kit's flag set and
no lock, provided the kit follows section 4.

This is a trust assumption on the kit's code, stated plainly: V3 cannot verify the lock at birth,
because the lock cannot exist at birth. A post-hoc monitor check is given in section 7.

### 2.3 Precedence

`V2` is evaluated first; if it answers 0 (fees disabled by the guardian or the Safe, a zero
override, a zero split) V3 returns 0 without calling the kit. Otherwise the kit is asked. Both
branches that return 0 are 0, so this order is a gas optimisation, not a policy choice.

The consequence that IS a policy choice: **a Safe per-pool override on V2 cannot put a fee on a
locked launch at birth.** The owner decision is "0 on kit-created locked pools (no double-dip)",
tenant control "none". The Safe keeps its V2 power to reprice any *existing* pool through
`V3.setPoolProtocolFee`, capped by core, and that is the documented escape hatch (section 7).

### 2.4 Why compose over the live V2 instead of copying it

`DeepCoreProtocolFeeControllerV2.protocolFeeForPool` is `external view override`, not `virtual`, and
its storage is `private`. Inheriting it cannot change the hot path. Editing V2's source to make it
virtual would change the source of a deployed, Sourcify-verified contract. So the real choice is
**copy V2 into V3** or **call V2**.

Calling the live V2 wins on attack surface and on migration risk:

| | Copy V2 into V3 | Compose over live V2 (chosen) |
|---|---|---|
| Fee config (split ratio, tier, dynamic, per-pool overrides) | re-entered on V3; any value missed during migration silently changes revenue | stays exactly where it is. Nothing to migrate, no divergence window |
| Guardian | new role on a new contract, must be re-appointed | V2's guardian, unchanged. `V2.emergencyDisableFees()` zeroes every non-launch pool created afterwards through V3 |
| Owner config powers and their caps | re-implemented | V2's own code, already tested and deployed |
| New privileged surface on V3 | the whole V2 surface again | four `onlyOwner` functions that only forward to core (core enforces caller and cap), one owner setter for the sweep destination, one permissionless sweep |
| Lines of new code to review | ~550 | ~250 |

What V3 must re-provide is only what core gates on `msg.sender == protocolFeeController`, since
V2 stops being that sender: `collect`, `sweep`, `setPoolProtocolFee`, `syncPoolToPolicy`. V2's
copies of those four start reverting `InvalidCaller` at the manager after the swap. That is
harmless, and it is recorded in section 6 so nobody reads the revert as an incident.

---

## 3. Hot-path discipline

`protocolFeeForPool` runs inside every pool creation on both managers.

1. **The kit call cannot brick pool creation.** It is a `staticcall` with a fixed stipend
   (`LAUNCH_ORACLE_GAS = 50_000`), at most 32 bytes of return data are copied (no return-data
   bomb), and any failure (revert, wrong size, a value other than exactly `1`) means "not a locked
   launch", which is the fee-charging branch. A broken or self-destructed kit costs the zero rule,
   never pool creation.
2. **The kit call cannot be gas-starved into a wrong answer.** Under EIP-150 a caller who controls
   gas could hand the kit less than its stipend and make an honest `true` fail. That direction
   only charges a fee (safe for revenue) but it would let a relayer or bundler charge a launcher.
   So V3 checks `gasleft()` against the stipend plus the 1/64 retention plus call overhead before
   calling, and reverts `InsufficientGasForLaunchCheck` below it. The answer is then a function of
   state, never of the caller's gas limit. This is the only revert V3 adds to the hot path, and it
   is not input-dependent: it fires exactly when the transaction did not bring enough gas.
3. **The V2 call is not caught.** V2's hot path never reverts on any input (its header and its
   fuzz test). If it ever did, V3 lets the revert through. Catching it and returning 0 would be a
   fail-open: a caller who can make V2 fail (for example by gas) would get a zero-fee pool for
   life. Failing closed means pool creation fails loudly instead.
4. **The zero rule never raises anything.** The only value the kit can influence is "0 or V2's
   answer". A malicious or buggy oracle can make pools free; it can never make one cost more than
   V2 says, and never more than core's cap.

---

## 4. Timing: exactly what kit v2 must do, in order, per CL leg

The fee is read inside `initialize`. The flag must therefore be written **before** `initialize`,
in storage `isLockedLaunch` reads, in the same transaction that locks.

```
createLaunch(p) nonReentrant, per CL leg i:
  1. key_i, poolId_i = build key (dynamic fee, LaunchGuardHook v2, CL manager)
  2. require !_lockedLaunch[poolId_i]                                   (no double record)
  3. EFFECT: _lockedLaunch[poolId_i] = true   (part of the leg record)  <- BEFORE any interaction
  4. hook.configureLaunch(key_i, cfg)   (claim; the hook's factory-token reservation
                                         admits the kit because deployerOf(token) == kit)
  5. clPoolManager.initialize(key_i, sqrtPrice_i)
        core -> hook.beforeInitialize (claim exists)
        core -> V3.protocolFeeForPool(key_i)
                  V2 says 999 per direction
                  kit.isLockedLaunch(poolId_i) == true  ->  0 is stamped
  6. mint the single-sided range to the KIT
  7. positionManager.safeTransferFrom(kit, locker, tokenId_i, abi.encode(LockParams))
  8. require locker.isLocked(tokenId_i) && locker.getLock(tokenId_i).poolId == poolId_i
  9. (recommended) (, , uint24 pf, ) = clPoolManager.getSlot0(poolId_i);
     if the installed controller is a V3 bound to this kit, require pf == 0
 10. launchRegistry.registerLaunch(...)
```

Rules, each of which the controller relies on and cannot check:

- **No `try`/`catch` around steps 4-8.** Atomicity is the whole argument in 2.2.
- **The flag is written in step 3 and nowhere else, and never cleared.** Not in
  `reconfigureLaunch`, not in any admin path. The kit v2 owner (Safe, launch fee only) must have
  no route to it.
- **Only legs that are locked set it.** A Bin leg, or any future unlocked launch shape, must
  answer `false`. An unlocked launch pays the core fee; that is the owner's rule.
- **`isLockedLaunch` must be a plain storage read.** No reentrancy-guard check (the kit is inside
  `nonReentrant` when core asks), no external calls, well under 50,000 gas, and it must return
  the ABI encoding of `bool` (exactly 32 bytes, value 0 or 1).
- **Key it by the exact `PoolId` passed to `initialize`.** The id hashes the manager, hook, fee,
  currencies and parameters, so it binds all of them; a record for one key says nothing about a
  sibling key.
- **Step 9 must not hard-revert while V2 is still installed.** Owner decision #2 keeps kit v2
  usable before V3, with the Safe zeroing each pool by hand. Gate the assertion on the installed
  controller answering `launchOracle() == address(this)`, read by a bounded `staticcall`.

What the pool-id reservation does and does not do here. The `LaunchGuardHook` rewrite reserves a
launch pool for the factory token's creator (`deployerOf(token)`, the kit for kit-created tokens)
or the claimer that creator appointed. That closes the grief where a front-runner claims or
initializes the launch pool first. **It is a liveness fix and not part of the fee predicate.** If
a squatter did initialize `poolId_i` first (on an older hook, or a hook without the reservation),
the kit had written no flag yet, so the squatter's pool is born paying V2's fee, and the kit's own
`initialize` then reverts `PoolAlreadyInitialized`, reverting its flag too. No fee is dodged in
either ordering.

### 4.1 If a locked launch were ever unlocked

Impossible by `DeepCoreLPLocker`'s design: it has no owner, no unlock, and its only position-manager
call is a zero-liquidity decrease plus take. Stated anyway: the fee was stamped at birth and core
never re-reads the controller, so the pool would stay at 0. V3 has no permissionless repricing, and
since 2026-09-18 `V3.setPoolProtocolFee` refuses a non-zero fee on any pool the kit flags
(`LockedLaunchPoolKeepsZeroFee`) — the flag is permanent, so on this controller the pool stays at 0
for good. Charging it would take a new controller that does not consult the kit, installed through
Custody: a public 48 h operation, not a Safe transaction.

---

## 5. Abuse analysis

| Attempt | Why it fails |
|---|---|
| Deploy a fake kit or fake registry that answers `true` for everything | V3 never consults it. The oracle is immutable and set at construction. |
| Create a pool on DeepCore's `LaunchGuardHook` without the kit | The kit wrote no flag for that id. V2's fee applies. |
| A pool id claimed or reserved on the hook by someone else (own factory token, appointed claimer) | Hook ownership is not an input. Only the kit's own flag is. V2's fee applies. |
| A hook that itself implements `isLockedLaunch -> true` | V3 calls `launchOracle`, never `key.hooks`. |
| Lock 1 wei of liquidity in the real locker for your own pool | The locker is not an input. |
| Front-run the kit and initialize its predicted pool | No flag exists yet: born paying the fee. Kit's launch reverts (grief, closed by the hook reservation). |
| Reenter mid-`createLaunch` to initialize a different pool while the flag is set | The flag is per `PoolId`, and a set flag's id is initialized by the kit in the same call; a second initialize of it reverts. |
| Starve the kit call of gas so an honest `true` reads as false | `InsufficientGasForLaunchCheck` reverts first. |
| Make the V2 call fail so V3 falls back to 0 | V3 has no such fallback; the revert propagates. |
| Oracle returns `2`, 64 bytes, or reverts with `abi.encode(true)` as revert data | Only `success && returndatasize == 32 && word == 1` counts. |
| Guardian tries to raise, reprice, collect or retarget | V3 has no guardian. V2's guardian can only `emergencyDisableFees` on V2, which only lowers V3's answers. |
| Owner exceeds the caps | V2's setters cap at 4000 pips. `setPoolProtocolFee` and `syncPoolToPolicy` are validated by core (`ProtocolFeeTooLarge`). |
| Anyone other than the owner calls a V3 setter or forwarder | `onlyOwner` on `collect`, `setPoolProtocolFee`, `syncPoolToPolicy`, `setTreasury`, `transferOwnership`. |
| `renounceOwnership` | Reverts `RenounceDisabled`. An unowned V3 could never collect again. |
| Redirect a permissionless `sweep` | No recipient argument. It pays the stored `treasury`, owner-set, never zero. |

What the Safe (owner) can still do, unchanged from V2: zero any pool it chooses (it always could,
via V2 overrides or `setPoolProtocolFee`), reprice any existing NON-launch pool within the cap,
collect to any non-zero recipient, and rescue a misdirected ERC-20 (`rescueERC20`, owner-only;
V3 custodies nothing, so any balance is a mistake). That is the V2 trust model and the ownership
table's "Safe" row, minus one power: a kit-flagged pool can only ever be set to 0 here
(`LockedLaunchPoolKeepsZeroFee`, acceptance finding B, 2026-09-18).

---

## 6. Migration

### 6.1 State this plan starts from

DeepCore is not deployed on any chain yet. The plan assumes the chain's core stack has been
deployed with both pool-manager owner wrappers (`CLPoolManagerOwner`, `BinPoolManagerOwner`)
handed to the custody timelock: the Safe transfers them, and `acceptOwnership()` is queued on the
timelock and executed after its 48 h delay.

**Do not install V3 with a direct Safe call** while the Safe still owns the wrappers. It would
work, and it would bypass the Custody tier the ownership table assigns to exactly this action.
Execute the queued accepts first, then read `owner()` on both wrappers: both must return the
custody timelock. Only then schedule.

### 6.2 Order

1. Kit v2 (with `isLockedLaunch`) is deployed. Its address exists.
2. Deploy V3: `script/DeployFeeControllerV3.s.sol` with `owner = Safe`, `policy = V2`,
   `launchOracle = kit v2`. The script asserts every immutable and probes the oracle.
3. After the accepts are executed and verified, the Safe proposes one `scheduleBatch` on the
   custody timelock (6.3). The 48 h public window starts.
4. During the window: anyone can read V3's code and immutables, and the canceller can veto.
5. After 172,800 s, anyone calls `executeBatch`. Both managers now ask V3.
6. Verify: `protocolFeeController()` on both managers returns V3; `V3.policy()` is V2;
   `V3.launchOracle()` is the kit; `V3.owner()` and `V3.treasury()` are the Safe.
7. Keeper: switch the `sweep` target from V2 to V3 at the execute block. The old target starts
   reverting `InvalidCaller` at the manager; the keeper simulates first, so that is a free read.
8. SDK / dapp: `feeController` becomes V3 for collection; fee **configuration** reads (split
   ratio, tier, dynamic, overrides, `feesDisabled`, guardian) stay on V2.

### 6.3 The timelock operation (calldata only, nothing sent)

One batch, both wrappers, so the two managers can never disagree about which controller is live.
Neither call can fail once the timelock owns both wrappers, so a batch strands nothing.

```
target      custody timelock <CUSTODY_TIMELOCK>   (Safe is sole proposer)
function    scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)   0x8f2a0bb0
targets     [<CL_POOL_MANAGER_OWNER>,    CLPoolManagerOwner
             <BIN_POOL_MANAGER_OWNER>]   BinPoolManagerOwner
values      [0, 0]
payloads    [0x2d771389 ++ pad32(V3), 0x2d771389 ++ pad32(V3)]    setProtocolFeeController(V3)
predecessor 0x0000000000000000000000000000000000000000000000000000000000000000
salt        keccak256("deepcore.install.feeControllerV3")
            = 0xec2bd2bbd4480d21219a0ee4eff85fe05849357898360aab2895b8d7a4a5a9f4
delay       172800   (== getMinDelay(); OZ rejects less with TimelockInsufficientDelay)

then, from any address, after the delay:
function    executeBatch(address[],uint256[],bytes[],bytes32,bytes32)   0xe38335e5
            same targets, values, payloads, predecessor, salt
```

Salt convention follows `ops/safe/BATCHES.md`: `keccak256("deepcore.<action>.<subject>")`, re-derivable
from its name, distinct from every `deepcore.handover.*` salt. Predecessor `0x0`. The wrapper
accepts are a precondition, but they are checked by reading `owner()` before scheduling rather
than encoded as predecessors: the three queued accepts are separate operations, and chaining the
install to one of them would add nothing the read does not already prove.

The exact bytes depend on V3's deployed address, which does not exist yet. They are produced by
`script/BuildInstallFeeControllerV3.s.sol`, which refuses the zero address and V2, checks the
V3 immutables on chain, and prints the `scheduleBatch` and `executeBatch` calldata plus the
operation id. Per `ops/safe/build-install-fee-controller-v2.mjs`: no file with a placeholder
address is ever written, because `setProtocolFeeController(address(0))` succeeds and silently
zeroes every future pool.

### 6.4 What happens to existing pools and money

- **Existing pools keep their stamped fee.** Normal pools stay at what V2 gave them. Kit launch
  pools created between kit v2 go-live and V3's execute pay 999 per direction unless the Safe
  zeroed them per the interim runbook. After V3, the Safe can fix any it missed with
  `V3.syncPoolToPolicy(manager, key)`, which resolves 0 for a kit-flagged pool, or
  `V3.setPoolProtocolFee(manager, key, 0)`.
- **Fees accrued under V2 are not lost.** They sit in `protocolFeesAccrued` on each manager and
  become collectable by V3 (`sweep` to the treasury or owner `collect`) the moment the batch
  executes. V2 loses the ability to collect at the same moment. There is no race: nobody but the
  installed controller can collect, before or after.
- **Rollback** is the same Custody operation pointing back at V2 (salt
  `keccak256("deepcore.install.feeControllerV2.rollback")`). Nothing is lost that way either.

---

## 7. Remaining risks and assumptions

- **The kit is trusted to set the flag only for pools it locks in the same transaction.** A kit
  bug that sets the flag without a lock yields zero-fee pools with no lock. Bounded to revenue,
  never user funds. Monitor: for every pool with `kit.isLockedLaunch(id)`, the kit's leg record
  names a `tokenId` with `locker.isLocked(tokenId)` and `locker.getLock(tokenId).poolId == id`.
  Remedy: a new V3 against a fixed kit, installed through Custody. `V3.setPoolProtocolFee` cannot
  reprice a flagged pool by design, so a kit that flags wrongly is a controller replacement, not
  a Safe transaction.
- **V3 is bound to one kit.** A tenant's own kit, or a future kit v3, gets the normal fee on the
  shared core until a new controller naming it is installed through Custody. That is the intended
  shape of "revenue is enforced by contracts DeepCore deploys": a tenant cannot award its own pools
  a zero core fee.
- **V3 depends on V2 staying the policy store.** V2 is immutable with renounce disabled; if its
  ownership moves, V3's fee configuration moves with it. V3's own owner is a separate
  `Ownable2Step` slot. Keep both on the Safe; the deploy script asserts they match at deploy.
- **Safe compromise** reaches exactly what it reaches under V2: fee levels within the cap, and
  collection. It does not reach the zero rule for launches, which no key can change.
- **Every gas figure** (`LAUNCH_ORACLE_GAS`, the reserve) assumes current EVM call pricing on the
  target chains. A future repricing that made a cold `SLOAD` exceed the stipend would make the
  zero rule fail closed (fees charged), not open.
