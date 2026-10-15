// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/**
 * The governance Safe of record, in ONE place, asserted on EVERY production chain.
 *
 * ######################### WHY THIS FILE EXISTS #########################
 *
 * Eleven deploy scripts each carried their own copy of the Safe address under the name
 * `ROBINHOOD_SAFE`, and each asserted it like this:
 *
 *     if (block.chainid == ROBINHOOD_CHAIN_ID) require(w.safe == ROBINHOOD_SAFE, "...");
 *
 * The name was the bug in miniature. DeepCore's ownership decision is that the SAME Safe address is
 * used on every chain (CLAUDE.md, "The governance Safe"), but calling the constant
 * `ROBINHOOD_SAFE` made it look chain-specific, and so the check was gated on that one chain. The
 * consequence was harmless while one chain was the only target and stopped being harmless the moment
 * a second production chain arrived: there the Safe-of-record comparison simply DID NOT RUN.
 * The scripts checked only that the owner had code and was not the deployer — which a wrong Safe,
 * a stale Safe, or an attacker's Safe all satisfy.
 *
 * ######################### IT FAILS CLOSED #########################
 *
 * The gate is inverted from how it was. It does NOT enumerate the chains to check; it enumerates
 * the chains to SKIP, and checks everything else. So a chain nobody has thought about yet — the
 * next Base, the next Anubis — is asserted BY DEFAULT rather than silently exempt. That inversion
 * is the whole point: the previous shape needed someone to remember to add a chain id, and the
 * failure of remembering was invisible.
 *
 * The skipped set is only local development and public testnets, where no Safe of record exists.
 * A testnet deployment therefore still gets the `code.length` and `!= deployer` checks, just not
 * the identity one.
 */
library DeepCoreGovernance {
    /**
     * The DeepCore governance Safe (owner, 2026-10-09: "use this safe wallet"; it replaces
     * 0xbd82…6DBF, whose record is void).
     *
     * Read on chain 2026-10-09: Safe v1.5.0, threshold 2 of 3, no modules, slot 0 = the 1.5.0 L2
     * singleton 0xEdd160fEBBD92E350D4D398fB636302fccd67C7e, owners (this order)
     * 0x5aD50DdE058b2c41298D9C5A33527a7E2150CD78, 0x1490fDC92438FD37032F63a97dC361D21265756d,
     * 0x5A785Fc7cD04b7aeB207A7154064ba178b6E288d: three plain wallets, none of them the deployer.
     * It exists on HyperEVM 999, Base 8453, BNB 56, Robinhood 4663 and Arc 5042. It is NOT yet created
     * on Monad, Ink, Cronos, Linea, Ethereum, Anubis or Sepolia; Cronos has no 1.5.0 L2 singleton at
     * that address, so the same Safe address may not be creatable there.
     *
     * `requireGovernanceSafe` still requires CODE at this address on the chain being deployed to, so a
     * production deploy refuses until the Safe has actually been created there (runbook §1).
     */
    address internal constant SAFE = 0xeEd90A15348bCAf234733aeB695cA95c0c068c8B;

    /**
     * @notice True where the Safe of record MUST own what is being deployed.
     *
     * Everything that is not a known development or test chain. Listed as an exclusion on purpose —
     * see the header.
     */
    function isProductionChain(uint256 chainId) internal pure returns (bool) {
        // anvil / hardhat / ganache defaults, and the chain ids the dev stacks pin.
        if (chainId == 31337 || chainId == 1337 || chainId == 1338) return false;
        // Public testnets: HyperEVM testnet, Sepolia, Base Sepolia, Stable testnet, Arc testnet. (Monad testnet was
        // dropped 2026-09-24 - owner decision; Monad MAINNET 143 is a production chain and is NOT here.)
        if (chainId == 998 || chainId == 11155111 || chainId == 84532 || chainId == 2201 || chainId == 5042002) return false;
        return true;
    }

    /**
     * @notice Assert that `candidate` is a usable governance owner for this deployment.
     *
     * Three checks, in increasing strength:
     *   1. it is a contract  — an EOA can never be the Safe, on any chain;
     *   2. it is not the deployer — the deploy key must not end up owning what it deploys;
     *   3. on a production chain, it IS the Safe of record.
     *
     * `label` names the environment variable so a failure says which input was wrong rather than
     * only that one was.
     */
    function requireGovernanceSafe(address candidate, address deployer, string memory label) internal view {
        require(candidate != address(0), string.concat(label, " is unset"));
        require(candidate.code.length > 0, string.concat(label, " has no code - the Safe, not an EOA"));
        require(candidate != deployer, string.concat(label, " is the deployer"));
        if (isProductionChain(block.chainid)) {
            require(SAFE != address(0), "DeepCoreGovernance: governance Safe of record is not set");
            require(candidate == SAFE, string.concat(label, " is not the governance Safe of record"));
        }
    }
}
