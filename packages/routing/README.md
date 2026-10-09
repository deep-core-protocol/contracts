# `@deepcoreprotocol/routing` — the routed-fill fee

GPL-2.0-or-later. Nothing deployed.

Two contracts that let DeepCore's router fill a user's trade on a venue DeepCore does not run, and take a
governed fee for it (owner decision, 2026-09-20: **10 bps on a routed fill, 0 on a DeepCore pool, the
same on every chain**).

| | |
|---|---|
| `DeepCoreFillRouter` | holds allowances, bounds the trade, takes the fee on the **input** side, pays out |
| `DeepCoreFillExecutor` | the only contract that makes the caller-chosen call. Nobody approves it. That is the whole point — see its file header. |

**This package imports nothing from `../core` or `../periphery`, and names no third-party venue
anywhere.** The venue is `address target` + `bytes data`, built off chain from a deployed contract's
public ABI. Nothing of anyone else's is vendored, imported or linked; the BUSL question never arises.
DeepCore pools still live only on DeepCore's own Infinity core, and a DeepCore-pool trade does not pass through
here at all.

```
forge build                          # cancun
FOUNDRY_PROFILE=legacy forge build   # shanghai
forge test --force                   # via-IR: always --force after editing source
```

- Design and the questions it had to answer first: `docs/routing-design.md`
- Security review, Slither triage, mutation run: `docs/routing-security-review.md`

**Not done yet:** the acceptance bar's live-transaction run (a devnet with a mock venue) and an
external audit. It sits in the swap path and handles user funds, so it gets the full bar.
