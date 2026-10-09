# LaunchpadKit v2: integration spec

Status: sections 1-9 are the **pre-implementation specification**; section 10 is the Bin locker as
built; **section 11, "Kit v2 (implemented)", is `LaunchpadKitV2` as built, and wins wherever it
differs from sections 1-9.** Sections 1-9 are kept because the reasoning in them still holds. The
specification composes three contracts that do exist:

| Contract | File | Role |
|---|---|---|
| `LaunchTokenFactory` / `LaunchToken` | `src/LaunchTokenFactory.sol`, `src/LaunchToken.sol` | plain fixed-supply ERC-20 at a CREATE2 address nobody can squat |
| `DeepCoreLPLocker` | `src/DeepCoreLPLocker.sol` | permanent custody of CL position NFTs, fee split fixed per lock, pull claims |
| `DeepCoreLaunchRegistry` | `packages/registry/src/DeepCoreLaunchRegistry.sol` | shared launch index, attribution by `msg.sender` |

Numbers come from CLAUDE.md "Kit fees: decided by the owner, 2026-09-13". Where this document
and that section disagree, that section wins.

---

## 1. What "Kit 1" does in one transaction

```
createLaunch(p) payable
  0. checks        launch fee == msg.value, N quotes in 1..maxQuotes, weights sum, split in bounds
  1. token         factory.createToken(name, symbol, uri, supply, address(kit), salt(msg.sender, p.salt))
  2. per quote i   build key_i  ->  record effects  ->  hook.configureLaunch(key_i)
                   ->  clPoolManager.initialize(key_i, sqrtPrice_i)
                   ->  mint single-sided CL range_i with supply_i of the launch token, to the KIT
                   ->  positionManager.safeTransferFrom(kit, locker, tokenId_i, abi.encode(LockParams))
                   ->  launchRegistry.registerLaunch(clPoolManager, poolId_i, token, kit, creator, steward, meta)
  3. remainder     any launch-token balance not seeded goes to p.creatorAllocationRecipient (or reverts, see 2.4)
  4. fees          launch fee to the Safe, integrator launch fee to the integrator
```

No quote currency is pulled. A single-sided range above spot (or below, when the launch token
sorts as `currency1`) holds only the launch token, so a launch quoted in NVDA never touches NVDA
at creation. That matters twice: the launcher needs no stock tokens, and an issuer pause of the
quote cannot block a launch.

### 1.1 Token creation and the salt

```solidity
bytes32 salt = keccak256(abi.encode(msg.sender, p.userSalt));
address token = factory.createToken(p.name, p.symbol, p.metadataURI, p.totalSupply, address(this), salt);
```

The factory folds ITS `msg.sender` (the kit) into the CREATE2 salt. That stops strangers
squatting a deployer's address, but every kit user shares the kit's namespace. **The kit must
fold the launcher into the salt it passes**, or one launcher can take another's mined vanity
address through the kit. `test_squatting_naiveKitSharesOneNamespace` demonstrates the attack on a
kit that forgets.

The SDK predicts the address with
`factory.predictTokenAddress(kit, keccak256(abi.encode(launcher, userSalt)))`, or off chain from
`factory.launchTokenInitCodeHash()`. The hash is constant for a factory build, so the MIT SDK
needs a 32-byte value read on chain and never ships GPL-derived bytecode.

**Known griefing vector, not theft.** The token address is predictable from the pending
transaction, and `LaunchGuardHook.configureLaunch` is first-claim with no code check on the
currencies. A front-runner can claim `poolId_i` before the token exists, making the kit's own
`configureLaunch` revert `NotLaunchOwner`. The whole launch reverts and nothing is lost. Retrying
with a new salt changes the address. Robinhood's sequencer is first-come-first-served with no
public mempool, which makes this hard there and easy on chains with a public mempool. A proper fix
belongs in the hook: let the kit reserve pool ids, or refuse claims on currencies with no code.
Both are hook changes and out of scope here.

### 1.2 Multi-quote launches (N pools, weights)

```solidity
struct QuoteLeg {
    address quote;          // any ERC-20, including Robinhood stock tokens; address(0) = native
    uint16  weightBps;      // share of the seeded supply; legs sum to exactly 10_000
    uint160 sqrtPriceX96;   // opening price, SDK-computed per leg
    int24   tickLower;      // single-sided range, validated below
    int24   tickUpper;
}
```

- `1 <= legs.length <= maxQuotes`. `maxQuotes` is an immutable constructor argument, a gas bound
  sized to the chain's block gas limit. Each leg costs roughly one `initialize`, one CL mint, one
  lock and one registry write.
- `supply_i = seedSupply * weightBps_i / 10_000`, floored, and **the last leg takes the
  remainder**, so the seeded total is exact. Dust is never stranded in the kit.
- Quotes must be pairwise distinct and never the launch token. With a fresh token, `quote != token`
  holds automatically.
- **Single-sidedness is validated, not trusted.** This is the same ordering rule as
  `CreatorReserve`: when the launch token is `currency0`, require `tickLower >= currentTick` after
  `initialize`; when it is `currency1`, require `tickUpper <= currentTick`. Getting that backwards
  does not revert in core. It produces a range made of the quote currency and a mint that pulls
  quote the launcher never sent. Validate the range against the tick core actually reports, not a
  tick computed from the requested price.
- Every leg's position goes through the same `safeTransferFrom` with the same `LockParams`. One
  launch yields N locks, and each lock is separately collectable.

### 1.3 Routing the position into the locker

```solidity
tokenId = positionManager.nextTokenId();
// modifyLiquidities(CL_MINT_POSITION(key, lo, hi, L, max0, max1, owner = address(this), ""), SETTLE_PAIR)
IERC721(address(positionManager)).safeTransferFrom(
    address(this), address(locker), tokenId,
    abi.encode(LockParams({creator: p.creator, creatorBps: c, integrator: p.integrator,
                           integratorBps: i, protocolBps: pr}))
);
```

Rules the kit must follow, each tied to a behaviour of the real contracts:

1. **Mint to the kit, then `safeTransferFrom`.** Never mint with `owner = locker`.
   `CLPositionManager._mint` uses solmate `_mint`, which fires no receiver callback. A position
   minted straight to the locker has no lock record, and nobody can ever attach one.
2. The transfer must happen **after** `modifyLiquidities` returns. `CLPositionManager.transferFrom`
   is `onlyIfVaultUnlocked`, and the Vault is locked during the mint.
3. Liquidity must be non-zero. The locker rejects `EmptyPosition`, because a zero-liquidity
   position can never be poked for fees.
3b. The pool's hook must not register `beforeRemoveLiquidity` or `afterRemoveLiquidity`. The
   locker rejects `HookInterceptsRemoval`, because every fee collection is a zero-liquidity removal.
   Such a hook could revert and block collection forever, or return a delta
   (`afterRemoveLiquidityReturnsDelta`) that takes the fees before the split, bypassing the 20%
   protocol floor. `LaunchGuardHook` (bitmap `0x0041`) passes this check.
4. The kit should assert `locker.isLocked(tokenId)` afterwards and read back
   `getLock(tokenId).protocolBps`. That is cheap, and it turns "the locker accepted what we meant"
   into a checked fact.
5. The kit must also check at construction that `locker.positionManager() == positionManager` and
   `locker.minProtocolBps() >= 2_000`. A kit pointed at a tenant's own locker with a zero floor is a
   full fork and should look like one.

### 1.4 Registry

The kit calls `launchRegistry.registerLaunch(address(clPoolManager), poolId, token, address(this),
creator, steward, metadata)` itself. `msg.sender == launchpad` makes the record
`LaunchpadAttested` and impossible to front-run, because it sits in the transaction that created
the pool. The kit should also implement `IDeepCoreLaunchOrigin.launchOriginOf(poolId)`, returning the
recorded creator, and call `registerLaunchpad(address(this), steward, meta)` once from its own
address so the listing is `SelfRegistered`.

---

## 2. Storage and ABI changes (v1 -> v2)

### 2.1 New immutables (constructor arguments, per the tenant-config rule)

| Name | Type | Notes |
|---|---|---|
| `tokenFactory` | `ILaunchTokenFactory` | shared, one per chain |
| `locker` | `IDeepCoreLPLocker` | DeepCore-deployed. Constructor checks its position manager and floor |
| `launchRegistry` | `IDeepCoreLaunchRegistry` | may be `address(0)` only if listing is explicitly off |
| `maxQuotes` | `uint8` | gas bound |
| `maxLaunchFeeWei` | `uint256` | immutable cap on the protocol launch fee |
| `launchFeeNoticeSeconds` | `uint32` | ≈ 7 days, measured against `block.timestamp` (see 4) |
| `maxIntegratorLaunchFeeWei` | `uint256` | cap on the tenant's add-on fee |
| `protocolFeeRecipient` | `address` | the governance Safe |

### 2.2 New storage

```solidity
uint256 public launchFeeWei;                  // current protocol launch fee
uint256 public pendingLaunchFeeWei;           // queued increase
uint64  public pendingLaunchFeeEffectiveAt;   // block.timestamp at which it may be applied

struct LaunchRecordV2 {
    address operator;          // as v1
    address launchToken;
    address creator;
    uint64  createdAt;         // block.timestamp
    bool    launchTokenIsCurrency0;
}
mapping(PoolId => LaunchRecordV2) records;        // one per leg; operator etc. shared
mapping(address token => PoolId[]) poolsOfToken;  // bounded by maxQuotes
mapping(PoolId => uint256) lockedTokenId;         // leg -> locker position
```

### 2.3 ABI

```solidity
struct LaunchParamsV2 {
    string  name; string symbol; string metadataURI; bytes32 userSalt;
    uint256 totalSupply;
    uint256 seedSupply;                  // <= totalSupply; the rest goes to creatorAllocationRecipient
    address creatorAllocationRecipient;  // required iff seedSupply < totalSupply
    QuoteLeg[] legs;
    int24   tickSpacing;
    uint32  startDelaySeconds;           // startTime = block.timestamp + this; see 4
    uint32  decaySeconds;                // Preset.Custom only
    Preset  preset;
    address creator;                     // lock creator and registry creator
    uint16  creatorBps; uint16 integratorBps; uint16 protocolBps;  // the locker validates
    address integrator;                  // tenant fee wallet, or 0
    uint256 integratorLaunchFeeWei;      // <= maxIntegratorLaunchFeeWei
    address launchOperator;
    LaunchMetadata listing;              // registry metadata: EXACTLY four `string`s —
                                         // description, websiteURI, xHandle, telegramHandle
                                         // (handles without `@`, [A-Za-z0-9_], 15 / 32 bytes,
                                         // "" = not given; no iconURI — the icon lives in
                                         // `metadataURI`). A 5th member or a bytes32 costs the
                                         // kit ~900 B and breaks EIP-170; see IDeepCoreLaunchRegistry
}

function createLaunch(LaunchParamsV2 calldata p) external payable returns (LaunchResultV2 memory);
function predictLaunchToken(address launcher, bytes32 userSalt) external view returns (address);
function proposeLaunchFee(uint256 newFeeWei) external;   // onlyOwner (Safe)
function applyLaunchFee() external;                      // permissionless once matured
function cancelLaunchFee() external;                     // onlyOwner
function launchOriginOf(bytes32 poolId) external view returns (address);

event LaunchCreatedV2(address indexed token, address indexed creator, address indexed operator,
    uint256 totalSupply, uint256 seedSupply, uint8 legs, uint256 launchFeeWei, address integrator,
    uint256 integratorLaunchFeeWei);
event LaunchLegCreated(address indexed token, PoolId indexed poolId, address indexed quote,
    uint256 lockedTokenId, uint128 liquidity, uint16 weightBps);
event LaunchFeeProposed(uint256 feeWei, uint64 effectiveAt);
event LaunchFeeChanged(uint256 previousWei, uint256 newWei);
```

The schedule fields match the timestamp-based kit: `LaunchResult` reports `startTime` and
`decaySeconds`.

### 2.4 Rules that are easy to get wrong

- **The launch token is fresh, so it can never be fee-on-transfer.** v1's `_pullExact` machinery
  is not needed for the launch side and must not be reused to accept arbitrary launch tokens. v2
  only launches tokens it just created.
- `seedSupply < totalSupply` without a recipient must revert. Leaving tokens in the kit would be
  an unowned balance on a contract with no withdrawal, which is the same class of bug
  `LaunchpadKit`'s header already rules out.
- The kit must hold **zero launch-token balance** at the end of `createLaunch`. Assert it.
- `msg.value` must equal `launchFeeWei + integratorLaunchFeeWei` exactly, plus the native seed
  when a leg is native-quoted. That seed is always zero in a single-sided launch, because native
  only ever sorts to `currency0` and the range holds the launch token. Refuse surplus instead of
  refunding it.

---

## 3. Fee layers

| Layer | Where it is enforced | DeepCore default | Tenant control |
|---|---|---|---|
| Protocol launch fee | kit v2 `createLaunch` | flat wei, set by the Safe inside `maxLaunchFeeWei` | none |
| Integrator launch fee | kit v2 `createLaunch` | 0 | per launch, `<= maxIntegratorLaunchFeeWei` |
| Locked-LP fee split | `DeepCoreLPLocker` | protocol **>= 20%**, cap 50%; integrator cap 20% | chooses inside the bounds, fixed forever per lock |
| Launch tax (creator tax) | `LaunchTaxModule` in both launch guards | protocol **>= 10% of the tax** (immutable floor, cap 50%) | rates (<= 10%), expiry (<= 180 d), buckets, integrator share (<= 20%); tenants cap rates and force their share |
| Core swap protocol fee | pool manager via fee controller | **0 on kit-created locked pools** | none |

### 3.1 Protocol launch fee (flat wei)

- `launchFeeWei <= maxLaunchFeeWei`, where the cap is immutable. The owner is the Safe via
  `Ownable2Step`, and `renounceOwnership` reverts. **This gives the kit an owner that v1 never
  had.** The owner's only power is this fee. Add it to CLAUDE.md's ownership table as
  `LaunchpadKit v2 owner -> Safe`.
- **Increase:** `proposeLaunchFee(x)` with `x > launchFeeWei` stores
  `pendingLaunchFeeEffectiveAt = block.timestamp + launchFeeNoticeSeconds`. `applyLaunchFee()` is
  permissionless after that time. A pending proposal is visible on chain and in an event for the
  whole notice window.
- **Decrease:** `proposeLaunchFee(x)` with `x <= launchFeeWei` applies immediately and clears any
  pending increase. Delay never sits on privilege reduction.
- **Never retroactive:** the fee is charged once, at `createLaunch`, at the value in force in that
  block. Nothing about an existing launch reads it again.
- **Avoid the RevShareHook §5 trap.** A matured proposal must not stay armed forever. Give it an
  expiry: it can only be applied within `launchFeeNoticeSeconds` after maturity, and after that it
  must be re-proposed. A UI must also show a pending increase next to the current fee.
- Payment is **pushed** to `protocolFeeRecipient` (the Safe accepts native). The integrator fee is
  pushed to `p.integrator`. Push is acceptable here, and not in the locker, because the
  integrator is chosen by the same caller who pays. A reverting integrator only blocks its own
  launches, never somebody else's.
- A USD-denominated fee needs an oracle and is out of scope. The Safe re-prices wei by hand.

### 3.2 Launch tax (Creator Economy hook) - IMPLEMENTED 2026-09-18 as the "creator tax" in the guards

The "min 10% of tax to protocol" floor belongs in the hook, as an immutable lower bound validated
at configuration, following the same pattern as `DeepCoreLPLocker.minProtocolBps`. The kit only
passes the split through. It must not be the enforcement point: anyone can configure a pool on
the hook without going through the kit.

**Where it lives.** A pool has one hook and every kit pool already runs a launch guard, so the tax
is a module both guards inherit (`packages/hooks/src/launch/LaunchTaxModule.sol`), not a second
hook: `LaunchGuardHook` and `BinLaunchGuardHook` gain `afterSwap | afterSwapReturnsDelta` (bitmaps
`0x08C1` / `0x08C5`), a third constructor argument `protocolRecipient` (the Safe), and
`configureTax(key, TaxConfig)` under exactly the freeze `configureLaunch` has (until `startTime`
or the first swap). Design of record: `docs/creator-tax-acceptance.md`.

| | |
|---|---|
| rates | `buyBps` / `sellBps`, each <= `MAX_TAX_BPS` = 1_000 (10%), on the UNSPECIFIED side of the swap (the output of an exact-in trade), taken once, in `afterSwap`, as a hook delta minted to the guard as ERC-6909 claims |
| expiry | `expiresAt` in `(now, now + 180 days]` at configuration; zero tax from `expiresAt` on with no transaction; the kit sets it to `startTime + taxSeconds` |
| buckets | `creatorBps + protocolBps + integratorBps == 10_000`; protocol in `[MIN_PROTOCOL_BPS 1_000, MAX_PROTOCOL_BPS 5_000]`; integrator <= `MAX_INTEGRATOR_BPS` 2_000; a bucket with a share needs a recipient and vice versa |
| money path | `RevShareHook`'s: `pendingTax[poolId][currency]` pot + `totalOwed[currency]` in `afterSwap`; permissionless `settleTax` splits a pot (remainder to protocol); pull `claim(currency, to)` / `claimFrom(pools, currency, to)`; permissionless `redeem`; permissionless `skim` credits `backing - totalOwed` to the immutable protocol recipient |
| Bin | while a tax is live the ACTIVE bin refuses mints (`TaxedActiveBinMintBlocked`): a lopsided active-bin mint is a swap the tax cannot see. Other bins, seeding and the Bin locker (burns only) are unaffected |

**Kit side (this package).** `LaunchParamsV2.tax` (`TaxParams`: `buyBps`, `sellBps`, `taxSeconds`,
`creatorBps`, `protocolBps`, `integratorBps`; all zero = no tax) is resolved by `_resolveTax`
(creator bucket -> `creator`, integrator bucket -> `integrator`, `expiresAt = startTime +
taxSeconds`) and configured on every leg by `LaunchLegs` right after the guard claim.
`reconfigureLaunch(token, keys, schedule, tax)` restates it (all-zero clears it); the per-leg loop
now lives in `LaunchLegs.reconfigure` (kit size). `LaunchRecordV2.integrator` is recorded for that.
Tenant policy: `TenantConfig.maxTaxBps` caps both rates (0 forbids a tax through that tenant) and
`TenantConfig.taxIntegratorBps` is the integrator share a tenant launch must restate
(`TaxNotAllowed`). The kit asserts at construction that both guards pay `protocolFeeRecipient`
and share caps (`HookTaxMismatch`), and caches `maxTaxBps` / `maxTaxIntegratorBps` for tenant
validation. Every other rule is the guard's and surfaces from the guard's address through the kit.

### 3.3 Core protocol fee = 0 on kit-created locked pools, and what V2 can actually do

This was read from `packages/fees/src/DeepCoreProtocolFeeControllerV2.sol`, the controller each chain's
managers are wired to first (`packages/fees/script/DeployFeeControllerV2Chain.s.sol`).

**What exists:**

1. `setPoolFee(PoolId poolId, bool isSet, uint16 zeroForOne, uint16 oneForZero)`, `onlyOwner`.
   It is a per-pool override with the **highest precedence** in `protocolFeeForPool` (after the
   `feesDisabled` kill switch). Core reads the controller **once, at `initialize`**
   (`ProtocolFees._fetchProtocolFee`). This therefore only affects a pool that does not exist yet.
   Pool ids are deterministic, so the Safe *can* pre-set `(poolId, true, 0, 0)` for a known key.
2. `setPoolProtocolFee(address poolManager, PoolKey key, uint24 newProtocolFee)`, `onlyOwner`.
   It forwards to `ProtocolFees.setProtocolFee`, the only way to reprice a pool that **already
   exists**. Passing `0` zeroes it.
3. `syncPoolToPolicy(poolManager, key)`, `onlyOwner`, pushes whatever `protocolFeeForPool`
   currently resolves.

**What does not exist:** any rule that recognises a kit-created or locked pool automatically.
Every kit pool is dynamic-fee (`LPFeeLibrary.DYNAMIC_FEE_FLAG`), and V2 deliberately defaults
dynamic pools to `DYNAMIC_FEE_PIPS = 999` per direction (`_dynamicFee`, set in the constructor).
**Without action, every kit v2 pool is born paying 999 pips of core protocol fee.** Launches are
permissionless and unscheduled, so a Safe transaction per pool (options 1 or 2) is a manual
process that cannot keep up. Every pool created before its transaction lands pays the fee.

**How to get 0 automatically.** A `DeepCoreProtocolFeeControllerV3` whose hot path adds one rule
ahead of the dynamic default:

```solidity
// inside protocolFeeForPool, after feesDisabled and the per-pool override:
if (address(poolKey.hooks) == address(launchGuardHookV2)) {
    (bool ok, bytes memory ret) = address(kitV2).staticcall{gas: 30_000}(
        abi.encodeCall(IKitV2.isLockedLaunch, (PoolId.unwrap(poolKey.toId())))
    );
    if (ok && ret.length == 32 && abi.decode(ret, (bool))) return 0;
}
```

- This works because `createLaunch` writes the per-leg record **before** `initialize`. v1 already
  orders effects that way, so the record is visible to the controller during the `initialize`
  staticcall.
- `isLockedLaunch(poolId)` must return true only for a leg whose position the same transaction
  will lock. If the lock fails, the transaction reverts and the record goes with it, so the flag
  cannot outlive a failed lock.
- The hot path **must not revert**. The gas-capped `staticcall`, exact-size decode and fallthrough
  to the normal rule are what keep pool creation alive if the kit is ever self-destructed or
  misbehaves. That is the same discipline the V2 header documents.
- Installing V3 is `CLPoolManagerOwner.setProtocolFeeController`, the **Custody (48h)** tier. Pools
  created under V2 in the meantime keep 999 pips until the Safe calls
  `setPoolProtocolFee(manager, key, 0)` on each.
- Key the rule to the kit, not only to `hooks == launchGuardHook`. Anyone can create a pool on that
  hook without locking anything, and the hook check alone would exempt those pools.

---

## 4. Wall-clock requirements

Owner decision (CLAUDE.md §3b): **every duration in DeepCore contracts uses `block.timestamp`.** On
Arbitrum Nitro chains such as Robinhood (4663), the EVM's `block.number` is Ethereum L1's, so a
block count is not a local clock at all. This spec assumes the timestamp-based `LaunchpadKit` and
`LaunchGuardHook` that are being written now: `startTime` and `decaySeconds`, with no block-time
parameter anywhere.

1. **No block-denominated value in the v2 ABI or storage.** The launch schedule is
   `startTime = uint64(block.timestamp) + p.startDelaySeconds`, computed in the transaction, so a
   transaction that waits in a mempool cannot land with a start already in the past. Custom
   launches pass `decaySeconds`. Presets carry seconds natively, so nothing gets converted.
2. The hook freezes a launch's config at `block.timestamp >= startTime`, and its fee decay is a
   function of `block.timestamp - startTime`. The kit forwards both unchanged.
3. Launch-fee notice (`launchFeeNoticeSeconds`) and proposal expiry are seconds against
   `block.timestamp`.
4. `DeepCoreLPLocker` has no durations. `Lock.lockedAt` is `block.timestamp`. `LaunchTokenFactory`
   has no clock. Neither contract reads `block.number`.
5. Off-chain (keeper, UI, SDK): compare contract timestamps against block header timestamps, never
   against `eth_blockNumber`.

---

## 5. Kit v1

DeepCore deploys kit v2 only; kit v1 (`LaunchpadKit.sol`) is not deployed on any chain. For the record
of how v1 differs: it has no owner, no pause and no upgrade path; it is bound to a block-clocked
guard; its launches stay `Claimed` in `DeepCoreLaunchRegistry` because it does not implement
`launchOriginOf` (v2 launches are `LaunchpadAttested`). Any holder of a CL position NFT can lock it
voluntarily with `safeTransferFrom(holder, locker, tokenId, abi.encode(LockParams))`; nothing in the
locker is kit-specific. The fee controller change in 3.3 must be live before kit v2 opens to the
public if the "0 core fee on locked pools" promise is part of launch.

---

## 6. Bin positions: why the locker is CL-only, and the design for a Bin locker

**Decision: `DeepCoreLPLocker` implements CL positions only.** Bin support is a separate contract,
`DeepCoreBinLPLocker`, designed below and not implemented. There are two reasons, both read from this
fork rather than assumed from Liquidity Book.

**Reason 1: Bin shares cannot authenticate a lock.** Bin positions are not ERC-721 or ERC-1155.
`BinFungibleToken` (`packages/periphery/src/pool-bin/BinFungibleToken.sol`) is a bespoke
multi-token with `balanceOf(owner, id)`, `approveForAll` and `batchTransferFrom`, and
`batchTransferFrom` **calls no receiver hook**. There is no `onERC1155Received` to implement. The
CL locker's core safety property ("the only way to create a lock is the transfer itself, so only
the previous owner chooses the split") is unavailable. A Bin locker must instead *pull*:
`lockBin(poolKey, ids, amounts, params)` with `batchTransferFrom(msg.sender, locker, ...)`. That
requires the sender to `approveForAll(locker)` over **all** their bin positions, which is a much
larger standing approval than a single ERC-721 transfer.

**Reason 2: Bin fees cannot be collected without burning liquidity.** In `BinPool.swap`
(`packages/core/src/pool-bin/libraries/BinPool.sol`), LP fees are added to the bin's reserves:
`reserveOfBin[activeId] = binReserves.add(amountsInWithFees).sub(amountsOutOfBin)`. Nothing accrues
per position, and there is no equivalent of the CL zero-liquidity poke. The only way to realise a
bin fee is `BIN_REMOVE_LIQUIDITY`, which **burns shares**. "Liquidity never decreases" stops being
a structural fact about which calls exist and becomes an arithmetic claim about how many shares a
harvest may burn.

**Design for `DeepCoreBinLPLocker` (if the owner wants Bin launches locked):**

- Per `(poolId, binId)`, record `sharesLocked` and `principalLiquidityPerShare`
  (`reserves.getLiquidity(price) * 1e18 / totalSupply` at lock time). At a bin's fixed price, an
  in-bin swap conserves `price * x + y` and adds the fee, so liquidity-per-share is non-decreasing.
  The things that raise it are swap fees, composition fees and donations. Nothing lowers it.
- `harvest(poolId, binIds[])` is permissionless. For each bin it computes
  `burn = shares * (1 - principalLps / currentLps)`, **rounded down**, removes exactly that, and
  credits the proceeds through the same three-way pull split. The invariant becomes: remaining
  shares × current LPS >= locked principal liquidity, per bin. Test it as an invariant with a
  rounding-direction mutation.
- A bin-count cap per lock (for example 64) bounds harvest gas. Bins that price has never crossed
  hold one token and accrue nothing, so skipping them is correct rather than lossy.
- The hazards to spec before building: `MINIMUM_SHARE` behaviour when a bin's supply drops near
  1e3, hooks with `beforeBurn` / `afterBurnReturnsDelta` (they can revert or tax a harvest), and
  the fact that `approveForAll` is all-or-nothing for the locker.

That is a second contract with its own audit surface. Folding it into the CL locker would make the
CL locker's guarantee depend on Bin arithmetic, for no benefit to CL locks.

---

## 7. Shaped Bin curve launches: kit-side validation

A Bin launch seeds one-sided bins of the launch token above (or below) the active bin, in a
chosen shape, through `BinPositionManager`'s
`BinAddLiquidityParams { deltaIds[], distributionX[], distributionY[], ... }`. Distributions are
1e18-precision fractions of `amount0`/`amount1` (`LiquidityConfigurations.PRECISION`). The kit
builds these arrays from a preset or validates a custom shape before calling:

1. **Single-sided.** For a launch token that is `currency0`, every `deltaId > 0` (strictly above
   active) and every `distributionY == 0`. Mirror the rule for `currency1`. The same ordering bug
   described in 1.2 applies.
2. **Monotonic prices.** `deltaIds` strictly increasing (strictly decreasing for `currency1`). Bin
   price is a pure function of id and `binStep`, so this is the price-monotonicity check.
3. **No gaps below the floor.** `deltaIds[k+1] == deltaIds[k] + 1` from the first bin up to
   `floorBins`. A gap near the opening price is a region with no liquidity where one trade moves
   price across the hole. Gaps above the floor (a stepped shape) are allowed and must be declared.
4. **Bin-count gas cap.** `deltaIds.length <= maxBins`, an immutable constructor argument sized to
   the chain's gas limit. Each bin is an SSTORE-heavy mint, and the same count bounds the future
   `DeepCoreBinLPLocker.harvest`.
5. **Totals.** `sum(distributionX) == 1e18` exactly, not `<=`. Otherwise the unallocated fraction
   silently stays with the kit. The minted launch-token amount must equal `seedSupply`, measured
   by the kit's balance delta across the call. The kit must end with zero launch-token balance.
6. **Per-bin sanity.** Every `distributionX[k] > 0`, because a zero-weight bin is a gap that looks
   filled, and `minLiquidities[k] > 0`.

**Named presets** (the kit computes the arrays; users choose a name and `binCount`):

| Preset | Shape of `distributionX[k]` | Use |
|---|---|---|
| `Flat` | `1e18 / n` each, remainder to the last bin | even sell wall; closest to a fixed-price sale |
| `Linear` | proportional to `n - k` | more depth near open, thinning upward |
| `Exponential` | proportional to `r^k`, `r < 1` fixed per preset (for example 0.9) | deep open, long thin tail; price discovery |
| `Stepped` | `m` equal tiers of contiguous bins, tier weights decreasing, fixed gaps between tiers | "rounds"; the gaps are the declared exception to rule 3 |
| `Custom` | caller arrays, rules 1-6 enforced | anything else |

Rounding in every preset: compute each weight floored, then give the last bin
`1e18 - sum(previous)`, so rule 5 holds exactly.

---

## 8. Locker design decisions, recorded

| Decision | Chosen | Trade-off |
|---|---|---|
| Hook filter | refuse pools whose hook registers a remove-liquidity callback | Stops a hook from bricking or skimming collection. It does NOT stop a tenant hook that keeps the LP fee near zero and charges a hook fee instead: the locker's floor applies to LP fees only, so kit v2 must launch only on DeepCore hooks. |
| Lock entry | `safeTransferFrom` + `onERC721Received` only | Authenticated by the transfer. A plain `transferFrom` or a direct mint to the locker is unrecoverable. That is documented, and it is the price of having no "attach" function a stranger could call. |
| Split | per lock `creatorBps / integratorBps / protocolBps`, sum 10 000, fixed forever; immutable `minProtocolBps` 2000, `maxProtocolBps` 5000, `maxIntegratorBps` 2000 | The floor is DeepCore's enforced revenue on DeepCore's locker. A tenant deploying their own locker can set anything. That is the full-fork path, and it is allowed. |
| Rounding dust | creator and integrator floored, **protocol gets the remainder** | Deterministic. The protocol never gets less than its bps. At most 2 base units extra per currency per collect. |
| Integrator | per lock address + bps, not an immutable locker slot | One shared locker serves every tenant. An immutable slot would force one locker per tenant and fragment the "one verified contract" moat. |
| Integrator rotation | none | Point it at a Safe, whose signers rotate without the address changing. Per-lock rotation for a tenant with thousands of locks would be thousands of transactions. |
| Creator rotation | 2-step (`transferCreator` / `acceptCreator`), no delay; credited balances stay with the old address | Lets a launcher move a hot key to a Safe, or sell the fee right. A delay would add nothing: whoever holds the key can already claim every future credit. |
| `protocolRecipient` | immutable | A setter needs an owner key able to redirect the protocol share of every lock at once. The Safe's address is stable across signer rotation. Cost: if the Safe itself is lost or compromised, protocol share on existing locks is lost with it, and only new locks on a new locker escape. |
| Payments | pull, per party, per currency, `claim(currency, to)` | A paused or blocklisting token blocks only its own claims. `to` lets a blocklisted party redirect. |
| Crediting | measured balance delta around the position-manager call | Correct for fee-on-transfer. Positive rebases and donations become surplus, which `skim` sends to protocol. |
| Stray native | `receive` only from the Vault | Only forced native (a self-destruct) can arrive uninvited, and `skim` handles it. |
| Token deploys | full CREATE2 deploy with a parameter callback, not EIP-1167 clones | +~0.7M gas once per token. In exchange: no DELEGATECALL on every transfer for the token's life, no initializer, a constant init-code hash (so vanity salts are reusable and the MIT SDK ships no bytecode), and identical bytecode for verification. |

---

## 9. Open questions for the owner

1. **Kit v2 gains an owner** (the Safe) for the launch fee. v1 had none by design. Confirm this,
   and add the row to the ownership table.
2. **Fee controller V3** (3.3) is the only way to make "0 core fee on locked pools" automatic, and
   installing it is a 48h Custody operation. Until then, is a manual `setPoolProtocolFee` per pool
   acceptable, or should kit v2 wait for V3?
3. **Bin launches**: build `DeepCoreBinLPLocker` (section 6), or ship Bin shapes unlocked at first?
4. **Pool-id squatting on predictable token addresses** (1.1) needs a hook-side fix. Should the
   `LaunchGuardHook` rewrite reserve pool ids for a registered kit?
5. **`skim` beneficiary** is the protocol. The alternative is to leave surplus stranded. Confirm.

---

## 10. Bin locker (implemented)

Status: **implemented** as `src/DeepCoreBinLPLocker.sol` + `src/interfaces/IDeepCoreBinLPLocker.sol`, with
`script/DeployDeepCoreBinLPLocker.s.sol`. Section 6 above is the problem statement; this section is the
design that was built, and where it refines section 6 (per-lock rather than per-bin records, pull
entry authenticated by `msg.sender`), this section wins. Every claim below was read from this fork's
`BinPool.sol`, `BinHelper.sol`, `BinPositionManager.sol` and `BinFungibleToken.sol`.

### 10.1 The guarantee, stated as the CL locker states it

| | `DeepCoreLPLocker` (CL) | `DeepCoreBinLPLocker` (Bin) |
|---|---|---|
| Principal | position liquidity `L`, never decreases | per bin: the lock's shares are always worth at least the bin-liquidity they were worth at lock time |
| Fee collection | zero-liquidity decrease; structurally cannot touch `L` | burns only the share count whose value EXCEEDS that principal; arithmetic, rounded against the burn |
| Split | per lock, fixed, floor 2000 / cap 5000 / integrator cap 2000, dust to protocol | identical, same `LockParams`, same `splitAmount` |
| Payouts | pull, per party, per currency | identical |
| Entry | `safeTransferFrom` + `onERC721Received` | `lock(key, binIds, shares, params)` pulls from `msg.sender` |
| Admin | none | none |

### 10.2 What "principal" and "fee" mean for a bin

A Bin pool bin has one fixed price `P` (Q128, a pure function of `binId` and `binStep`). Core measures
a bin's value as `L = P·x + y·2^128` (`BinHelper.getLiquidity`). Three facts from the fork make `L`
the right unit:

1. **An in-bin swap conserves `L` exactly, before fees.** `getAmountsOut` / `getAmountsIn` price every
   unit at `P` and round in the bin's favour (input rounded up, output rounded down), so a swap adds
   `ΔL >= 0` plus its LP fee. The protocol's cut `pFee <= totalFee` is removed before it reaches the
   reserves (`BinPool.swap`, `getProtocolFeeAmt`), so the LP fee part can only raise `L`.
2. **Nothing crosses bins.** A swap that exhausts a bin moves to the next one; no operation moves
   value from one bin's reserves to another's. Per-bin accounting is therefore exact, not an
   approximation. (This is the property CL does not have, and why CL needs fee-growth accounting.)
3. **`L / totalShares` is non-decreasing under every core operation.** Swaps (fact 1), third-party
   mints (`shares = floor(userL·S/binL)`, surplus input trimmed only down to the effective liquidity),
   third-party burns (`amountOut = floor(burn·reserve/S)`), composition fees (credited to existing
   shares before the minter's shares are computed) and `donate` all leave `L/S` equal or higher.

So for a single-sided launch position, **selling launch tokens to buyers does not change `L`**: a bin
that was 100% launch token and is now 100% quote token holds the same `L`, plus fees. The quote
tokens received for sold launch tokens ARE the principal, in a different currency, and stay locked
as the pool's buy-back depth. That is exactly what the CL locker already does with a single-sided
CL range that is bought through, so it is the owner's approved model rather than a new decision:
**sale proceeds are principal and are never withdrawn by anyone; the protocol floor applies to fees
only.**

Definitions, per lock `k` and bin `b`:

```
shares[k][b]     locked share count, written at lock, decreased only by collectFees
principal[k][b]  = ceil(sharesAtLock · L_b / S_b)       bin-liquidity units, written once
value[k][b]      = shares[k][b] · L_b / S_b              at any moment

INVARIANT  value[k][b] >= principal[k][b]                for every lock, bin and block
fee        = value - principal                            (swap fees, composition fees, donations,
                                                            and third-party rounding dust)
```

`collectFees` burns, per bin, `burn = shares - ceil(principal · S / L)`, so the shares that remain
satisfy `remaining · L / S >= principal` before the burn; and because core pays the burn out floored,
the burn itself raises `L/S` for the shares that remain. The two rounding directions both point at
the principal. Mutating either one fails `testFuzz_harvestableShares_neverCrossesPrincipal`
(`test/DeepCoreBinLPLocker.fuzz.t.sol`).

**What this does NOT mean, stated plainly.**

- **Fees are delivered in the bin's CURRENT composition, valued at the bin's price.** Bin fees are not
  tracked per token by core; they are part of `L`. A fee paid in quote by a buyer, harvested after
  sellers have swapped the bin back to launch token, is delivered as launch token worth the same `L`
  at `P`. If the market has since fallen below `P`, that launch token is worth less than the fee was
  when it was paid. Uncollected fees therefore carry the position's price exposure until someone
  calls `collectFees`. Mitigation: harvest often (it is permissionless, and the keeper can do it).
  Not an extraction path: a caller who swaps a bin's composition to change what the parties receive
  pays swap fees that are themselves harvested, and moves no value to himself.
- **Fees accrued BEFORE the lock are principal.** The share price at lock time is the baseline. A kit
  locks in the same transaction as the mint, so this is zero for kit launches. A holder who locks an
  old position voluntarily forfeits its uncollected fees into the permanent principal. The CL locker
  differs (it collects pre-lock fees), because CL tracks fees separately and Bin cannot.
- **Principal in TOKEN terms moves with price**, as for any LP position. The guarantee is in bin
  liquidity at each bin's own price, which is the same unit core uses for everything.

### 10.3 Options evaluated

**(a) Track principal per bin, burn only the excess — CHOSEN, refined as above.** Measured in `L`
rather than in reserve amounts, which is what makes it correct under price movement. Cost: the
no-withdraw property is an arithmetic claim about one function instead of a structural absence of
calls, so it is guarded by an invariant suite, a per-bin fuzz and mutation checks rather than by
reading the call list alone.

**(b) Lock shares forever and route revenue through the pool's hook fee (RevShareHook).** Rejected.
It does make the no-withdraw property structural (the locker would never call the position manager
again), but it fails the brief in three ways: the locked-LP revenue line in "Kit fees" becomes zero
(LP fees compound into the bins forever and nobody receives them); the hook fee is configured by the
pool owner through `proposeConfig` / `reduceFee` / `disable`, so the split is neither per-lock nor
immutable; and it forces every Bin launch onto one hook. A hook fee is a legitimate SECOND layer (the
"launch tax" row), not a replacement for this one.

**(c) Alternatives found in the fork, rejected:**

- *Reserve snapshots* (`x0, y0` at lock, harvest what exceeds them): wrong by construction. A bought
  bin has `x < x0`, so it reads as a loss while it is a sale at `P`; a harvest keyed to `y > y0` would
  pay sale proceeds out as fees and put the protocol floor on them.
- *Locker mints directly on core with a per-lock salt* (`BinPoolManager.mint` keys positions by
  `(owner, binId, salt)`): isolates each lock's shares natively and makes orphans impossible, but
  turns the locker into a Vault-locking liquidity app that must settle tokens and re-implement the
  position manager's slippage checks. Much larger surface, and it does not change the fee problem.
- *One lock per bin, shares read from `balanceOf`*: avoids per-lock share storage, but any stray
  transfer to the locker would silently become harvestable "fee", and two locks in the same bin
  (a kit lock plus a later voluntary lock) would be impossible.

### 10.4 Entry without a receiver callback

`BinFungibleToken.batchTransferFrom` calls no hook, so the lock pulls:

```solidity
function lock(PoolKey calldata key, uint24[] calldata binIds, uint256[] calldata shares, LockParams calldata p)
    external returns (uint256 lockId);
// inside: positionManager.batchTransferFrom(msg.sender, address(this), tokenIds, shares)
```

- **Authentication** is `msg.sender`: the account whose shares move is the only one who can choose
  the split, which is the property `onERC721Received` gave the CL locker. The pull source is hard-coded
  to `msg.sender`; there is no `from` parameter.
- **The standing approval is bounded by that.** `approveForAll(locker, true)` is all-or-nothing over
  the approver's bin shares, but the locker can only ever exercise it inside a `lock` call the
  approver makes itself. A third party cannot pull anyone's shares through the locker.
- **Receipt is measured**: `balanceOfBatch` before and after, and every bin must arrive exactly.
- **Orphans.** Shares sent to the locker with a plain `batchTransferFrom` have no lock record and are
  stranded forever: no function burns, moves or attributes them, and a harvest never touches more
  than a lock's own recorded shares. They stay in the pool as permanent liquidity. An "attach" or
  "skim shares" function was rejected: attach is front-runnable (first caller names the creator),
  and a share-skim would add a second burn path whose correctness depends on summing every lock.
- **Same-transaction atomicity for the kit**: mint to the kit, then `lock` after `modifyLiquidities`
  returns (`batchTransferFrom` is `onlyIfVaultUnlocked`), all inside `createLaunch`.

### 10.5 Hazards addressed

| Hazard | Handling |
|---|---|
| Hook runs on burn (`beforeBurn`, `afterBurn`, `afterBurnReturnsDelta`) | refused at lock (`HookInterceptsRemoval`): every harvest is a burn, and such a hook could block it or take the proceeds before the split |
| `BinPool__ZeroAmountsOut` / `BurnZeroAmount` would revert a whole multi-bin harvest | bins whose burn floors to zero out are skipped; if every bin is skipped, `NothingToCollect` (a free read for keepers) |
| `MINIMUM_SHARE` / bin removed from the tree | a harvest always leaves `ceil(principal·S/L) >= 1` shares, so it never empties a bin it holds |
| Gas | `maxBinsPerLock` immutable constructor argument, bounds both `lock` and `collectFees` |
| Pool manager paused | `BinPoolManager.burn` is not `whenNotPaused`, so collection still works |
| Paused / blocklisting quote token | the whole harvest reverts, fees stay in the bins and keep compounding, retry after unpause; credited balances wait in `claimable` |
| Fee-on-transfer quote | credit is the measured balance delta |
| Reentrancy | `nonReentrant` on every mutating entrypoint; shares are decremented before the position-manager call |
| Duplicate bin ids in one lock | refused: ids must be strictly increasing |
| LP fee kept near zero by a tenant hook | NOT handled, as for CL (section 8): the floor applies to LP fees |

### 10.6 What kit v2 calls, in order, for one Bin leg

```
constructor (once)   require(binLocker.positionManager() == binPositionManager)
                     require(binLocker.minProtocolBps() >= 2_000)
                     require(maxBins <= binLocker.maxBinsPerLock())
                     binPositionManager.approveForAll(address(binLocker), true)
createLaunch, per Bin leg:
  1. record leg effects (so the fee controller V3 can see isLockedLaunch during initialize)
  2. hook.configureLaunch(key)                               // if the hook needs it
  3. binPoolManager.initialize(key, activeId)
  4. read activeId back; validate shape rules 1-6 of section 7 against it
  5. binPositionManager.modifyLiquidities(
         BIN_ADD_LIQUIDITY(key, amount0, amount1, max0, max1, activeId, idSlippage 0,
                           deltaIds, distX, distY, minLiquidities, to = address(kit), ""),
         SETTLE_PAIR(currency0, currency1))
  6. for each bin: shares[i] = binPositionManager.balanceOf(kit, toTokenId(poolId, binIds[i]))
                   (fresh pool: the whole balance is this mint)
  7. lockId = binLocker.lock(key, binIds (strictly increasing), shares, LockParams)
  8. assert binPositionManager.balanceOf(kit, tokenId_i) == 0 for every bin
     assert binLocker.getLock(lockId).protocolBps == intended; isLocked(lockId)
  9. launchRegistry.registerLaunch(address(binPoolManager), poolId, token, kit, creator, steward, meta)
```

Never mint with `to = binLocker`: those shares arrive without a record and are orphans (10.4).

---

## 11. Kit v2 (implemented)

Status: **implemented and tested, not deployed.** Where this section and sections 1-9 disagree, this
section wins; where it and CLAUDE.md disagree, CLAUDE.md wins.

| File | What it is |
|---|---|
| `src/LaunchpadKitV2.sol` | the kit: checks, the V3 flag, records, fees, tenants, reconfiguration, views |
| `src/libraries/LaunchLegs.sol` | linked library: the interaction phase (token, every leg's open/seed/lock/register) |
| `src/libraries/BinLaunchShapes.sol` | internal library: named Bin shapes and rules R1-R6 |
| `src/interfaces/ILaunchpadKitV2.sol` | params, records, events, errors |
| `src/interfaces/ILaunchRegistryWriter.sol` | the five `DeepCoreLaunchRegistry` calls the kit makes |
| `script/DeployLaunchpadKitV2.s.sol`, `script/DeployBinLaunchGuardHook.s.sol` | deploy scripts (never broadcast here) |
| `packages/hooks/src/launch/BinLaunchGuardHook.sol` | pool-id reservation ported from the CL guard |
| `test/kitv2/*` | 93 tests; `test/fork/TimestampRedeployRehearsal.t.sol` gains a kit v2 rehearsal |

### 11.1 A new contract, not a replacement of `LaunchpadKit.sol`

v1 has no owner and no retirement path (section 5), and v2 shares
almost nothing with it: a different ABI, an owner, both pool types, locking, a factory token.
So v2 is `LaunchpadKitV2` in new files, and `LaunchpadKit.sol` and its tests are untouched.

### 11.2 Why a linked library, and what that costs

The kit in one piece compiled to **42,889 bytes** at the package's 1,000,000 runs, against
EIP-170's 24,576. At 9,000 runs (the existing `clPosm` profile, shared so a test that deploys
`CLPositionManager` and the kit resolves to one profile) it was still 26,444. The interaction phase
therefore moved into `LaunchLegs`, reached by one `DELEGATECALL`:

| Contract (9,000 runs) | Runtime bytes, default | Runtime bytes, legacy |
|---|---|---|
| `LaunchpadKitV2` | 22,479 | 22,459 |
| `LaunchLegs` | 19,324 | 19,350 |

What makes the delegatecall safe, stated so a reviewer can check each point:

- The library address is written into the kit's bytecode at link time. No setter, no proxy, no
  storage slot holds it. A library has no storage and no `selfdestruct`.
- Solidity's library call guard makes `execute` revert when CALLed directly, so it is not a free
  launcher anybody can drive. A contract that DELEGATECALLs it only acts in its own context.
- It runs in the kit's context: every call it makes is FROM the kit, which is what the guards'
  reservation, the position NFT, the bin shares and the Bin locker's `msg.sender` pull all require.
- It reads and writes no kit storage. The kit writes every flag and record before calling it and
  records the returned lock ids after.
- `msg.value` is visible inside it (delegatecall preserves it). It never uses it: fees are credited
  by the kit before, and the refund is paid by the kit after.

Deployment consequence: `forge script` deploys `LaunchLegs` as its own transaction before the kit,
and the library must be verified alongside the kit.

### 11.3 Storage layout

Read with `forge inspect src/LaunchpadKitV2.sol:LaunchpadKitV2 storageLayout`. No proxy, so this
matters for audit and indexers, not for upgrades.

| Slot | Variable | Type |
|---|---|---|
| 0 | `_owner` (Ownable) | `address` |
| 1 | `_pendingOwner` (Ownable2Step) | `address` |
| 2 | `_status` (ReentrancyGuard, plain storage in both builds) | `uint256` |
| 3 | `_launchFeeWei` | `uint256` |
| 4 | `_pendingLaunchFeeWei` | `uint256` |
| 5 | `_pendingLaunchFeeEffectiveAt` | `uint64` |
| 6 | `_lockedLaunch` - **the V3 flag** | `mapping(bytes32 => bool)` |
| 7 | `_legs` | `mapping(bytes32 => LegRecord{launchToken, kind, launchTokenIsCurrency0 \| lockId})` |
| 8 | `_launches` | `mapping(address => LaunchRecordV2{creator, createdAt, legCount \| operator, startTime \| tenant})` |
| 9 | `_legsOfToken` | `mapping(address => bytes32[])`, at most `maxLegs` |
| 10 | `feesOwed` | `mapping(address => uint256)` |
| 11 | `totalFeesOwed` | `uint256` |
| 12 | `_tenants` | `mapping(address => TenantConfig)` (integrator, bps, fee, masks, flags, `maxTaxBps`, `taxIntegratorBps`) |
| 13 | `tenantQuoteAllowed` | `mapping(address => mapping(address => bool))` |

`LaunchRecordV2` gained a fourth slot, `integrator`, on 2026-09-18 (the creator tax's integrator
bucket, restated by `reconfigureLaunch`).

Immutables: both pool managers, both guards, both position managers, both lockers, the factory,
the launch registry, both Permit2s (read off the position managers), `protocolFeeRecipient`,
`launchpadSteward`, `maxLaunchFeeWei`, `launchFeeNoticeSeconds`, `maxIntegratorLaunchFeeWei`,
`maxLegs`, `maxBinsPerLeg`, `maxIntegratorBps` (read off the lockers) and the factory's
`launchTokenInitCodeHash`. Every tenant-facing value is a constructor argument or a call argument.
The constants are protocol safety bounds and units: the two guard bitmaps, the 20% LP floor the
lockers must enforce, `MAX_LEGS_HARD_CAP = 8`, notice in [1 day, 30 days], and the guards' 30-day
start-delay cap, which the constructor asserts equal on both guards.

Constructor checks (each a named revert): one Vault behind both managers, both position managers
and the launch registry; each position manager on its manager; each guard on its manager, with
the right bitmap (`0x41` CL, `0x45` Bin), `CLOCK_MODE() == "mode=timestamp"`, and
`LAUNCH_TOKEN_FACTORY` equal to the kit's factory; both lockers on their position managers, paying
`protocolFeeRecipient`, with identical bounds and a floor of at least 20%; `maxBinsPerLeg` at most
the Bin locker's `maxBinsPerLock`; the fee cap and notice. It then `approveForAll(binLocker)` on the
Bin position manager, the kit's only standing approval.

### 11.4 `createLaunch`: the step order

**Checks and effects - no call of any kind** (EXTCODESIZE reads only):

1. `1 <= legs <= maxLegs`; `0 < seedSupply <= totalSupply`; an allocation recipient iff
   `seedSupply < totalSupply`; creator, integrator and allocation recipient are not the kit.
2. Fees and tenant policy (11.6): integrator fee within its cap and with a recipient; an active
   tenant whose stored integrator, bps and fee equal the call's; the preset allowed;
   `msg.value >= launchFeeWei() + integratorFee`.
3. The schedule: preset or custom values, `startDelaySeconds <= 30 days`,
   `startTime = block.timestamp + startDelaySeconds`.
4. The token address, computed locally: `salt = keccak256(abi.encode(msg.sender, userSalt))`, then
   the factory's CREATE2 rule with its cached init-code hash. No call, so no call precedes the flags.
5. Per leg: quote is not the token and has code (or is native); a Bin leg's schedule is <= 10%; a
   preset that needs a buy cap has one on every CL leg; tenant quote and shape allowlists; the leg's
   supply (`seedSupply * weightBps / 10_000`, the last leg the remainder, non-zero, <= `uint128`);
   the pool key (dynamic fee, the guard, its bitmap and spacing or bin step); the pool id.
6. **`_lockedLaunch[poolId] = true`** and the leg record, for every leg, refusing a duplicate id.
7. Weights sum to exactly 10,000; the launch record; fee credits (`feesOwed`).

**Interactions - `LaunchLegs.execute`, one DELEGATECALL:**

8. Every Bin leg's shape is built (named) or taken (custom) and validated, R1-R6 (11.7), against the
   requested active id. Pure, and still before any call to another contract.
9. `tokenFactory.createToken(name, symbol, uri, totalSupply, kit, salt)`; assert the address equals
   step 4 and the kit received exactly `totalSupply`. Permit2 approvals to the position managers the
   legs use.
10. Per leg, in order, as below. Then `launchRegistry.registerLaunch(manager, poolId, token, kit,
    creator, steward, listing)` - `msg.sender` is the kit, so the record is `LaunchpadAttested`.
11. Transfer the remaining launch-token balance (unseeded allocation plus rounding dust) to the
    allocation recipient, or to the creator when there is none; assert the kit holds zero.

**Back in the kit:** write each leg's lock id; emit `LaunchCreated`; refund `msg.value` above the
fees to `msg.sender`, last.

**CL leg** (controller-v3.md section 4, steps 4-8; step 9 as specified):

```
clHook.configureLaunch(key, cfg)          claim: deployerOf(token) == kit
clPoolManager.initialize(key, sqrtPrice)  core -> guard.beforeInitialize; core -> V3 -> kit.isLockedLaunch == true -> 0
getSlot0 -> (sqrtPrice, tick, protocolFee)
assert protocolFee == 0 IF the installed controller's launchOracle() == kit   (bounded staticcall)
assert single-sided against core's tick: currency0 needs tickLower > tick; currency1 needs tickUpper <= tick
liquidity = LiquidityAmounts(sqrtPrice, lower, upper, supply on the launch side, 0)   (> 0)
tokenId = nextTokenId(); modifyLiquidities(CL_MINT_POSITION(..., owner = KIT), SETTLE_PAIR)
positionManager.safeTransferFrom(kit, clLocker, tokenId, abi.encode(LockParams))   after the Vault unlocked
assert clLocker.isLocked(tokenId), getLock(tokenId).poolId == poolId, ownerOf(tokenId) == clLocker,
       and creator / creatorBps / integrator / integratorBps / protocolBps as declared     (LockNotRecorded)
```

The single-side comparisons are strict, per the open `CreatorReserve` LOW: core keeps a position in
range for `tickLower <= tick < tickUpper`, so section 1.2's `tickLower >= currentTick` would accept a
range that already holds quote currency.

**Bin leg** (section 10.6, which it follows exactly):

```
binHook.configureLaunch(key, cfg)         claim: deployerOf(token) == kit (the ported reservation)
binPoolManager.initialize(key, activeId)  core -> V3 -> kit.isLockedLaunch == true -> 0
getSlot0 -> (activeId, protocolFee); assert activeId == requested (ActiveIdMoved); same gated fee assert
modifyLiquidities(BIN_ADD_LIQUIDITY(amount on the launch side, max = amount, idSlippage 0,
                  deltaIds, distX, distY, minLiquidities = 1 each, to = KIT), SETTLE_PAIR)
shares[k] = balanceOf(kit, tokenId_k)     fresh pool: the whole balance is this mint
lockId = binLocker.lock(key, binIds ascending, shares, LockParams)
assert balanceOf(kit, tokenId_k) == 0 for every bin                                 (KitRetainedBinShares)
assert isLocked(lockId), poolId, binCount and every split field as declared         (LockNotRecorded)
```

No `try`/`catch` exists anywhere in the kit or the library. Any failure reverts the launch:
token, pools, flags, locks, registry records and fee credits together
(`test_ATOMIC_lockFailureRevertsTheWholeLaunch`, `test_ATOMIC_secondLegFailureRevertsTheFirst`).

### 11.5 The V3 rules, and the Bin statement reconciled

Every rule in `packages/fees/docs/controller-v3.md` section 4 holds, in its strictest reading:

| V3 rule | Where it holds |
|---|---|
| flag before any external call | step 6, before the first call of any kind in the transaction |
| `configureLaunch` -> `initialize` -> mint to the kit -> `safeTransferFrom` -> assert `isLocked` + poolId | 11.4, both leg types |
| no `try`/`catch` between flag and lock | none exists in either file |
| `isLockedLaunch(bytes32)` a plain storage read, no reentrancy-guard check | `return _lockedLaunch[poolId];` |
| never clear the flag, no other path sets it | one write site; `reconfigureLaunch`, the owner and tenants never touch it |
| key it by the exact id passed to `initialize` | the id is computed from the same `PoolKey` value that is initialized |
| step 9 must not hard-revert under V2 | gated on `controller.launchOracle() == address(this)` |

**The Bin statement.** controller-v3.md says "a Bin leg ... must answer `false`", written when no Bin
locker existed. The rule it encodes is **never flag an unlocked leg**: an unlocked launch pays the
core fee. `DeepCoreBinLPLocker` now exists, so the rule, stated for both pool types, is:

> Flag a leg if and only if the same transaction initializes its pool, seeds it, and moves the
> seeded position into the DeepCore locker for its pool type - `DeepCoreLPLocker` for CL,
> `DeepCoreBinLPLocker` for Bin - and then proves the lock by reading it back (and, for Bin, that the
> kit retains zero shares of every seeded bin). Kit v2 has no unlocked leg shape, so every v2 leg is
> flagged. A future unlocked shape must answer `false`.

V3 needs no change: it reads the flag on both managers already (`FeeControllerV3LiveBin.t.sol`).

### 11.6 Fee model

**Protocol launch fee (Kit v2 decision #1).**

- Owner: the governance Safe, `Ownable2Step`, set in the constructor so the deployer never holds
  it. `renounceOwnership` reverts `RenounceDisabled`. The owner's only functions are
  `setLaunchFee`, `cancelPendingLaunchFee` and the two-step ownership transfer
  (`test_ACCESS_ownerHasNoOtherPower`).
- `setLaunchFee(x)`, with `x <= maxLaunchFeeWei` (immutable):
  - `x <=` the fee in force: **applied now**; any pending increase is cancelled.
  - `x >` the fee in force: **scheduled**, `effectiveAt = now + launchFeeNoticeSeconds`
    (immutable, 7 days in the deploy script). It becomes the fee **by itself** at `effectiveAt`. A
    newer increase replaces it and restarts the clock, so no announcement can shorten a wait.
- `launchFeeWei()` is the fee a launch in the current block pays. Nothing about an existing launch
  ever reads it again, so nothing is retroactive.
- **Why there is no apply step and no expiry**, which section 3.1 recommended: the RevShareHook
  item-5 hazard was a matured proposal that anybody could apply at a moment of their choosing. Here
  there is no application, so no optionality: the new value takes effect at a public, fixed
  timestamp announced a week earlier. A launcher's refund makes the transition safe: an increase
  landing between signing and inclusion either reverts `InsufficientLaunchFee` or is paid out of a
  surplus the launcher chose to send.

**Integrator (tenant) launch fee.** Per call, `integratorLaunchFeeWei <= maxIntegratorLaunchFeeWei`
(immutable), paid to `integrator`, which must be set when the fee is non-zero.

**Payment.** Both fees are **credited**, never pushed during a launch (`feesOwed`,
`totalFeesOwed`). `claimFees(to)` pays the caller's own balance. `flushProtocolFees()` is
permissionless and can only pay the immutable `protocolFeeRecipient`. A recipient that rejects
native currency cannot block anybody's launch (`test_INTEGRATOR_aRecipientThatRefusesNativeCannotBlockLaunches`).
`msg.value` below the total reverts; any excess is refunded to `msg.sender` at the very end, inside
`nonReentrant`. This supersedes section 2.4's "refuse surplus".

**Tenant configuration (self-service).** `setTenantConfig` and `setTenantQuote` write the
**caller's own** policy: the fee wallet (integrator), `integratorBps` (<= the lockers' cap), the
integrator launch fee (<= its cap), an allowed-preset mask, an allowed-Bin-shape mask, and an
optional quote allowlist. A launch naming `tenant` must restate the stored integrator, bps and fee
exactly (`TenantConfigMismatch`), so a tenant raising its fee can only make a pending launch revert,
never re-price it. The kit owner cannot write a tenant's config.

What this does NOT enforce, stated plainly: a launcher who calls the kit with `tenant = 0` pays no
tenant anything. A tenant config is a policy for launches that go through the tenant's front end
or wrapper contract, not a toll on the kit. The protocol launch fee, the lockers' 20% floor and the
zero core fee are the parts no caller can route around.

| Layer | Enforced by | Value |
|---|---|---|
| Protocol launch fee | kit, every launch | Safe-set wei, <= immutable cap, +7 days notice |
| Integrator launch fee | kit, per call / tenant config | <= immutable cap |
| Locked-LP split | both lockers, per lock, forever | protocol 20-50%, integrator <= 20% |
| Core protocol fee | V3 via `isLockedLaunch` | 0 on every kit leg, V2's value on everything else |

### 11.7 Bin shapes

Offsets and weights are in **fill order**: offset 1 is the bin next to the active bin on the launch
token's side. The kit maps them above active (launch token is currency0) or below it (currency1),
and hands the Bin locker ascending ids. So "single-sided" and "monotonic" read the same for both
orientations, and a caller cannot put a shape on the quote side.

| Rule | Refinement of section 7 | Error |
|---|---|---|
| R1 single-sided | every offset >= 1 | `BinShapeNotSingleSided(k)` |
| R2 monotonic prices | offsets strictly increasing | `BinShapeNotMonotonic(k)` |
| R3 no gap below the floor | `1 <= floorBins <= n` and `offsets[k] == k + 1` for `k < floorBins`; gaps allowed only after it | `BinShapeInvalidFloor`, `BinShapeGapBelowFloor(k)` |
| R4 bin cap | `1 <= n <= maxBinsPerLeg <= binLocker.maxBinsPerLock()`; equal lengths | `BinShapeBadCount`, `BinShapeLengthMismatch`, `InvalidBinCap` (constructor) |
| R5 totals | `sum(weights) == 1e18` exactly | `BinShapeWeightsDoNotSum(sum)` |
| R6 per-bin | every weight > 0, `floor(supply * weight / 1e18) > 0`, `minLiquidities = 1` | `BinShapeZeroWeight(k)`, `BinShapeDustBin(k)` |
| id range | currency0: `activeId + offset <= 2^24 - 1`; currency1: `offset < activeId` | `BinIdOutOfRange` |

Section 7's "the minted amount must equal `seedSupply`" cannot hold exactly: core floors each bin's
`amount * distribution / 1e18`. The kit measures what was spent, sends the dust (at most one unit
per bin) to the allocation recipient, and asserts it ends holding no launch token.

Named shapes (`BinShape`), all passing the same validator
(`testFuzz_SHAPES_namedShapesAlwaysValidate`, every size to 256):

| Shape | Weight of bin k | Offsets | floorBins |
|---|---|---|---|
| `Flat` | equal | 1..n | n |
| `Linear` | proportional to n - k | 1..n | n |
| `Exponential` | proportional to 0.9^k | 1..n | n |
| `Stepped` | tiers of 4 contiguous bins, tier weight decreasing, 2 empty bins between tiers | `1 + k + 2*floor(k/4)` | min(4, n) |

Weights are floored and the last bin takes `1e18 - sum`. The 10% Bin fee ceiling means
`AntiSniperAggressive` and `Stealth` (50%) are refused on a launch with any Bin leg
(`PresetUnavailableOnBin`); `FairLaunch`, `NoTax` and `Custom` up to 10% work.

### 11.8 Events and errors

Events: `LaunchCreated`, `LaunchLegCreated` (per leg, with the launch-token amount measured into the
pool), `LaunchReconfigured`, `LaunchFeeIncreaseScheduled`, `LaunchFeeChanged`,
`PendingLaunchFeeCancelled`, `FeesCredited`, `FeesClaimed`, `TenantConfigured`, `TenantQuoteSet`, plus
Ownable2Step's. `LaunchLegCreated` is emitted from the library and therefore by the kit's address.

Errors, grouped (full signatures in `ILaunchpadKitV2`):

| Group | Errors |
|---|---|
| construction | `ZeroAddress`, `NoCode`, `HookPoolManagerMismatch`, `UnexpectedHookBitmap`, `HookClockMismatch`, `HookFactoryMismatch`, `PositionManagerMismatch`, `VaultMismatch`, `LockerMismatch`, `LockerFloorTooLow`, `InvalidLegCap`, `InvalidBinCap`, `InvalidNotice`, `LaunchFeeAboveCap` |
| launch shape | `InvalidLegCount`, `LegWeightsDoNotSum`, `EmptyLeg`, `LegTooLarge`, `InvalidSeedSupply`, `AllocationRecipientRequired`, `InvalidRecipient`, `QuoteHasNoCode`, `QuoteIsLaunchToken`, `DuplicateLegPool`, `StartDelayTooLong`, `MaxBuyRequiredByPreset`, `PresetUnavailableOnBin`, `RangeNotSingleSided`, `SeedProducesNoLiquidity`, `BinIdOutOfRange`, `ActiveIdMoved`, and `BinLaunchShapes.BinShape*` |
| fees | `InsufficientLaunchFee`, `IntegratorFeeAboveCap`, `IntegratorFeeWithoutIntegrator`, `NothingToClaim`, `NoPendingLaunchFee`, `NativeTransferFailed`, `RenounceDisabled` |
| tenants | `TenantNotActive`, `TenantConfigMismatch`, `PresetNotAllowed`, `BinShapeNotAllowed`, `QuoteNotAllowed`, `InvalidTenantConfig` |
| atomicity and oracle | `LaunchTokenAddressMismatch`, `LaunchTokenSupplyMismatch`, `LockNotRecorded`, `ProtocolFeeNotZero`, `KitRetainedLaunchToken`, `KitRetainedBinShares` |
| reconfiguration | `UnknownLaunch`, `NotLaunchOperator`, `LegKeyMismatch` |

Errors raised inside the guards, lockers, factory, registry and core surface unchanged (for example
`DeepCoreLPLocker.IntegratorBpsTooHigh`, `LaunchGuardHook.LaunchAlreadyStarted`).

### 11.9 Gas budget (measured)

`test/kitv2/LaunchpadKitV2Gas.t.sol`: `gasleft()` around `createLaunch` against the real stack, a
cold first launch of a fresh token, managers, lockers, guards and registry already deployed. This
excludes the 21k intrinsic cost and calldata; on Nitro, the L1 data fee is additional.

| Launch | Gas |
|---|---|
| 1 CL leg, ERC-20 quote | 2,355,841 |
| 1 CL leg, native quote | 2,290,725 |
| 1 CL leg + 1 Bin leg (10 bins, Linear) | 5,960,643 |
| 1 Bin leg, 32 bins | 9,720,813 |
| 4 Bin legs x 20 bins (the deployment's worst case) | 24,361,606 |
| 4 Bin legs x 32 bins | 35,533,512 - over Nitro's 32,000,000 block |

Every figure includes the token deployment (a full CREATE2 deploy, section 8), the guard claims and
one registry record per leg. A Bin leg scales at roughly 0.3M gas per bin (core mint, the position
manager's per-bin bookkeeping, the Bin locker's per-bin principal record). That is why the deploy
script caps a launch at `maxLegs = 4` and `maxBinsPerLeg = 20`, and the worst case is asserted below
28.8M.

### 11.10 A stock-token quote paused mid-launch

A single-sided launch **never transfers the quote**: no quote is pulled, seeded, refunded or
approved, and the guards only read its code size (`test_REENTRANCY_maliciousQuoteIsNeverCalledByALaunch`
proves no ERC-20 function of the quote is called). So, for a Robinhood `Stock`-style quote:

| Moment of the pause | Effect |
|---|---|
| before or during `createLaunch` | none: the launch succeeds, born at zero, locked (`test_Stock_launchSucceedsWhileTheQuoteIsPaused`) |
| after the launch | buys revert (the buyer cannot pay); sells revert (the Vault cannot pay out); other legs of the same launch keep trading |
| collecting that leg's LP fees | `collectFees` reverts; the fees stay in the position (CL) or the bins (Bin) and keep accruing; nothing is lost |
| claiming credited fees in that token | `claim` for that token reverts until unpause; claims in the launch token are unaffected |
| after unpause | everything resumes (`test_Stock_pausedMidLaunchHaltsTradingNotTheLocks`) |
| `uiMultiplier` changes | none: core, the lockers and the kit account in raw units only |

The launch guard's clock keeps running during a pause. A pause spanning the decay window means
trading reopens at, or near, the final fee.

### 11.11 The Bin pool-id reservation (the open LOW, closed)

`BinLaunchGuardHook` now carries the CL guard's two rules verbatim: no first claim on a currency
without code, and a `LAUNCH_TOKEN_FACTORY` token's launch pools are claimable only by its
`deployerOf` or the claimer that creator appointed (`setLaunchClaimer`). The constructor gains the
factory argument (the ABI changes, the bitmap does not: `69`). Ten `test_RESERVE_*` tests; deleting
the two `_requireMayClaim` calls turns five red. No Bin guard is deployed on any chain, so nothing
migrates. Kit v2's constructor refuses a guard whose factory is not its own.

### 11.12 Deployment

Order, each step asserted by the next: CL locker + factory; Bin locker (same Safe, same bounds);
`LaunchGuardHook(clPoolManager, factory)`, listed; `BinLaunchGuardHook(binPoolManager, factory)`,
listed; `DeployLaunchpadKitV2` (owner = Safe from the constructor); `DeployFeeControllerV3` with
`LAUNCHPAD_KIT_V2` = the kit; then the 48 h Custody install on both manager-owner wrappers. Until
that executes, kit pools are born at V2's 999 pips and the runbook zeroes each in the launch session
(decision #2). The kit keeps working in that window: its zero-fee assertion only arms when the
installed controller names it (`test_SCRIPT_kitIsUsableBeforeItsV3IsInstalled`).

`DeployLaunchpadKitV2` probes the chain clock (`ContractClockProbe`) in `run()`, requires every input
to be a contract, the Safe to be the governance Safe of record on every production chain (refused
while `DeepCoreGovernance.SAFE` is unset), both guards timestamp-clocked
and bound to the factory, both lockers at the owner's numbers and paying the Safe, and after the
broadcast reads back every immutable, the owner, the empty pending fee, the Bin locker approval,
`renounceOwnership` reverting, `isLockedLaunch(0)` answering a 32-byte `false` inside V3's
50,000-gas stipend, and, when `FEE_POLICY_V2` is set, runs `DeployFeeControllerV3Script.checkInputs`
against the new kit so the V3 step cannot fail on inputs.

**Fork rehearsal.** `test_REHEARSE_kitV2LaunchOnTheLiveCore` deploys the whole stack through the real
scripts on a fork of a chain where DeepCore core is live (HyperEVM 999 once deployed), deploys a V3
bound to the kit, installs it on the managers by impersonating their owner chain (a fork-only
stand-in for Custody), and launches a native-quoted CL + 10-bin Bin launch. It skips without
`REHEARSAL_RPC_URL`. Nothing is broadcast.

### 11.13 What the kit does not protect, and residual risk

- **Stranded value by misdirection.** Launch tokens or native sent to the kit outside
  `createLaunch` are unrecoverable (no withdrawal; native only by `selfdestruct`, since there is no
  `receive`). A `creator` or `integrator` contract that cannot call the lockers' `claim` strands its
  own share. The kit itself is refused as a recipient.
- **Tenant fees are bypassable** by a launcher who does not name the tenant (11.6).
- **The Bin launch tax is capped at 10% by core**, and pre-start mint+burn acquisition on Bin remains
  the guard's documented residual risk. The kit seeds only non-active bins, so its own seeding pays
  no composition fee.
- **Protocol recipient immutability.** A lost or compromised Safe keeps receiving new launch fees
  until a new kit is deployed; a new kit also needs a new V3 (Custody).
- **Sequencer clock.** The notice delay and every guard window are `block.timestamp`, trusted within
  Nitro's bounds.
- **Registry metadata** passed by the launcher is free text; the registry's own rules apply.
- **Gas.** A launch at the caps costs ~24.4M gas; on a chain with a smaller block the caps are wrong
  and must be re-measured before deploying there.

## 12. The tenant front end (`packages/create-deepcore-app`), 2026-09-17

The MIT template is the intended way a tenant reaches this kit, and it reaches it through ABIs and
`@deepcoreprotocol/sdk` only (the licence boundary is a test: `does not import GPL protocol sources`).
What it holds, in the kit's own terms:

| Kit concept | Where the tenant sets it | What the app does with it |
|---|---|---|
| `tenant` / `TenantConfig` | `chain.launchTenant`, stored with `npm run deepcore:tenant` → `setTenantConfig` sent from the tenant key | every launch names it and restates the STORED integrator, bps and fee (11.6); `deepcore:verify` fails on drift between the config file and the chain |
| `integrator`, `integratorBps`, `integratorLaunchFeeWei` | `fee.wallet`, `launch.integratorBps`, `launch.integratorLaunchFeeWei` | shown on the wizard's split and the Fees screen; sent as plain arguments only for a direct launch (`tenant = 0`), which nothing enforces |
| `creatorBps` / `protocolBps` | the creator, per launch, inside the lockers' bounds read off chain; `launch.defaultProtocolBps` is the proposal | `creatorBps = 10000 − protocolBps − integratorBps`, refused below zero |
| `LegParams` | one to `maxLegs()` legs; CL: tick spacing + width in spacings; Bin: step, named shape, count | `kitV2CLLaunchRange` snaps a CL price onto the range edge, `binActiveIdForLaunch` snaps a Bin price onto a bin; the SNAPPED price is rendered, with the move |
| `msg.value` | — | `readLaunchValue().safeValue`, so a scheduled increase (11.6) cannot revert a signed launch; the kit refunds the surplus |
| `LaunchCreated` + `LaunchLegCreated` | — | the `/launch` list: per leg the guard's `currentFee`/`getLaunch` and the locker's `getLock`, read live |
| `feesOwed` / `claimFees`, lockers' `claimable` / `claim` / `collectFees` | — | `/launch/earnings` for the connected wallet |

Proven end to end on an anvil fork on 2026-09-17 (`script/DevKitV2Stack.s.sol`, one `STEP` per
`forge script` process — see CLAUDE.md for why), driving the template's own modules: bounds, tenant
config, build with zero SDK issues, `eth_call`, send (6.27M gas for a CL + Bin native-quoted launch),
list read-back with locks at 7500/500/2000, and the tenant's launch fee credited exactly. Not deployed
anywhere; `DeepCoreDeployment.launchpadV2` stays all `null`.
