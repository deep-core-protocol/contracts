/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

/// @notice Named launch configurations.
/// @dev `Custom` means "use the numbers I passed"; every other value overwrites the fee schedule
/// and window length with the preset's own, and ignores whatever the caller put there.
enum Preset {
    Custom,
    FairLaunch,
    AntiSniperAggressive,
    Stealth,
    NoTax
}

/// @notice The parameters a preset fixes. Everything else (start delay, per-transaction cap,
/// price, tick range, amounts) stays with the caller because a preset cannot know it.
struct PresetParams {
    /// @dev LP fee at the first block of the window, in pips (1e6 == 100%).
    uint24 initialFeeBips;
    /// @dev LP fee once the window has elapsed, in pips.
    uint24 finalFeeBips;
    /// @dev Length of the decay window, in SECONDS of `block.timestamp`, written to the hook as-is.
    uint32 windowSeconds;
    /// @dev When false the hook applies no gate and no decay; it pins the fee at `finalFeeBips`.
    bool enabled;
    /// @dev When true the preset is incoherent without a per-transaction cap, and the kit rejects
    /// a launch that does not supply one. See `LaunchpadKit.MaxBuyRequiredByPreset`.
    bool requiresMaxBuyPerTx;
}

/// @title LaunchPresets
/// @notice A tiny, opinionated set of launch configurations, so an integrator picks a name instead
/// of tuning five numbers whose interactions they have no reason to know.
///
/// @dev ########################### READ THIS BEFORE PICKING ONE ###########################
///
/// Every preset here is a PRICE, not a PROHIBITION. `LaunchGuardHook` taxes early buying on a
/// decaying schedule keyed to `block.timestamp`. It does not, and at this layer cannot, identify
/// who is buying: the `sender` a hook callback receives is the Vault locker (the router), not the
/// trader, and `hookData` is attacker-controlled. So:
///
///   * NO PRESET HERE OFFERS A PER-WALLET CAP, AN ALLOWLIST, OR A "ONE BUY PER ADDRESS" RULE.
///     None is implementable honestly, and shipping a fake one is worse than shipping none.
///   * `maxBuyPerTx` bounds ONE TRANSACTION. Splitting a buy across N transactions, or N wallets,
///     in the same block defeats it completely. It raises the gas cost of a large snipe; it does
///     not cap anyone's position.
///   * A sniper willing to pay the opening tax buys anyway. That is the design: the tax accrues to
///     the pool's liquidity providers as an ordinary LP fee, so early extraction is redistributed
///     rather than prevented.
///   * Nothing here governs the TOKEN. Transfer restrictions, mint authority, LP-token custody and
///     the launcher's own conduct are all outside the pool. A guarded pool does not make a token
///     safe; it makes ONE pool's first minutes expensive to front-run.
///   * Nothing here governs OTHER venues. A second pool, an OTC block, or a CEX listing routes
///     around every preset in this file.
///
/// These presets are CL (concentrated-liquidity) only. `BinLaunchGuardHook` is capped at a 10% LP
/// fee by core (`BinPool` validates against `LPFeeLibrary.TEN_PERCENT_FEE`), so `AntiSniperAggressive`
/// and `Stealth` are simply unreachable on a bin pool and the numbers below would revert there.
/// #####################################################################################
library LaunchPresets {
    /// @notice `Preset.Custom` was passed somewhere a concrete preset is required.
    error NoParametersForCustomPreset();

    /// @dev Pips, matching core: 1_000_000 == 100%.
    uint24 internal constant PIPS = 1_000_000;

    /// @notice Resolves a preset to its parameters.
    /// @dev Reverts for `Preset.Custom`, which by definition has no parameters of its own.
    // forge-lint: disable-next-line(internal-function-used-once)
    function params(Preset preset) internal pure returns (PresetParams memory p) {
        if (preset == Preset.FairLaunch) {
            // Opens at 10%, decays to a 0.30% standard fee over five minutes.
            //
            // PROTECTS AGAINST: a bot that buys in the first block for free. It pays 10% and the
            // 10% goes to the LPs.
            // DOES NOT PROTECT AGAINST: anything else in the contract note above. Five minutes is
            // short enough that a determined buyer simply waits it out - which is the point; the
            // goal is to remove the free money at the open, not to police the order book.
            return PresetParams({
                initialFeeBips: 100_000, // 10%
                finalFeeBips: 3_000, // 0.30%
                windowSeconds: 300, // 5 minutes
                enabled: true,
                requiresMaxBuyPerTx: false
            });
        }
        if (preset == Preset.AntiSniperAggressive) {
            // Opens at 50% - the hook's hard ceiling - and decays to 1% over thirty minutes.
            // Requires a per-transaction cap, because a 50% tax that a whale can pay once in a
            // single enormous buy is a worse outcome than a 50% tax they have to pay in slices.
            //
            // PROTECTS AGAINST: profitable first-block sniping under most launch price paths, and
            // a single oversized market buy.
            // DOES NOT PROTECT AGAINST: sybil splitting across wallets or transactions. Thirty
            // minutes of elevated fees also taxes genuine early buyers, and it makes the pool
            // unattractive to arbitrageurs, so the price can stay dislocated for the whole window.
            // This is the most punitive preset and it is punitive to everybody, not just bots.
            return PresetParams({
                initialFeeBips: 500_000, // 50%, LaunchGuardHook.MAX_INITIAL_FEE
                finalFeeBips: 10_000, // 1%
                windowSeconds: 1800, // 30 minutes
                enabled: true,
                requiresMaxBuyPerTx: true
            });
        }
        if (preset == Preset.Stealth) {
            // A short, very sharp window: 50% decaying to 0.30% over two minutes. Intended to be
            // paired with a start delay the launcher keeps pushing back until they are ready to
            // open, which `LaunchGuardHook.configureLaunch` permits while the start is in the
            // future.
            //
            // PROTECTS AGAINST: someone trading the pool before the launcher opens it. Swaps
            // revert until `startTime`, so liquidity can be seeded in the open with no risk of
            // being bought out first.
            // DOES NOT PROTECT AGAINST: observation. "Stealth" is about timing, not secrecy - the
            // pool, the hook config and the exact `startTime` are all public from the moment this
            // transaction lands, and a bot reading the chain knows the open second before you
            // announce it. It also does not stop the launcher from never opening at all; that is a
            // trust assumption on the launcher, which is why liquidity operations stay unhooked so
            // LPs can always withdraw.
            return PresetParams({
                initialFeeBips: 500_000, // 50%
                finalFeeBips: 3_000, // 0.30%
                windowSeconds: 120, // 2 minutes
                enabled: true,
                requiresMaxBuyPerTx: false
            });
        }
        if (preset == Preset.NoTax) {
            // No gate, no decay: the hook pins the LP fee at 0.30% and otherwise stays out of the
            // way. This is NOT the same as launching without a hook - a dynamic-fee pool stores an
            // LP fee of 0, so something must supply one on every swap or the pool is free to trade
            // through. Use this when you want the launch plumbing (one-call setup, a registry
            // listing, the option to reconfigure before the open) without the tax.
            //
            // PROTECTS AGAINST: nothing. It is a plain 0.30% pool with a hook attached.
            return PresetParams({
                initialFeeBips: 3_000,
                finalFeeBips: 3_000,
                // The hook's `MIN_DECAY_SECONDS`. Irrelevant to the fee - the schedule is flat and
                // disabled - but the hook validates every config against the same bounds.
                windowSeconds: 60,
                enabled: false,
                requiresMaxBuyPerTx: false
            });
        }
        revert NoParametersForCustomPreset();
    }
}
