// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  BaseAddresses — Base Mainnet contract registry
/// @notice address constants for fork tests. All addresses verified
///         on basescan.org. Inherit this contract to get typed constants at zero
///         runtime cost.
abstract contract BaseAddresses {
    // ── USDC (Circle native, 6 decimals) ─────────────────────────────────────
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ── Aave V3 on Base ──────────────────────────────────────────────────────
    address internal constant BASE_AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant BASE_AAVE_ATOKEN_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    // ── Morpho MetaMorpho — Steakhouse USDC vault (ERC-4626) ─────────────────
    address internal constant BASE_MORPHO_STEAKHOUSE = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;
}
