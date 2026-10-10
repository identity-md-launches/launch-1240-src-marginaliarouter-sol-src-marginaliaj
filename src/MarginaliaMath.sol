// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Pure score arithmetic for Marginalia, kept out of the hook for code size. No state, no owner.
contract MarginaliaMath {
    /// @dev IMD-denominated market-cap tiers for the difficulty score (~$1M / ~$10M at IMD ≈ $9).
    uint256 public constant TIER2_MCAP_IMD = 111_000 ether;
    uint256 public constant TIER3_MCAP_IMD = 1_110_000 ether;

    /// @notice log2(claimed multiple) × sqrt(30 / horizon) × mcap tier, scaled 1e4.
    /// @param targetBps the claimed price as a multiple of the post price in basis points
    /// @param buy true for a BUY call (target > 1), false for a SELL call (target < 1)
    /// @param horizonDays 1..90
    /// @param mcapImd the token's market cap at post time, in IMD (1e18)
    function difficulty(uint32 targetBps, bool buy, uint16 horizonDays, uint256 mcapImd) external pure returns (uint256) {
        uint256 ratio = buy ? targetBps : FullMath.mulDiv(10_000, 10_000, targetBps);
        uint256 l2 = log2x1e4(ratio);
        uint256 s = sqrt(FullMath.mulDiv(30, 1e8, horizonDays)); // sqrt(30/h) × 1e4
        uint256 tier = mcapImd >= TIER3_MCAP_IMD ? 3 : (mcapImd >= TIER2_MCAP_IMD ? 2 : 1);
        return FullMath.mulDiv(l2, s, 1e4) * tier;
    }

    /// @dev log2 of a ratio given ×1e4 (ratio ≥ 1e4), returned ×1e4 with 1/16 precision.
    function log2x1e4(uint256 r) public pure returns (uint256 result) {
        uint256 n;
        while (r >= 20_000) {
            r /= 2;
            n += 1;
        }
        result = n * 1e4;
        uint256 frac = 5000;
        for (uint256 i = 0; i < 4; ++i) {
            r = r * r / 1e4;
            if (r >= 20_000) {
                result += frac;
                r /= 2;
            }
            frac /= 2;
        }
    }

    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
