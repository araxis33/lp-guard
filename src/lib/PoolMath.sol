// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ICLPool, ICLGauge, ILeafVoter, ISugarHelper} from "../interfaces/IAero.sol";
import {MulDiv} from "./MulDiv.sol";

/// @title PoolMath
/// @notice Readings of an Aero (Slipstream) pool that PositionGuard needs: its average price, its
///         reward counter brought up to date, and what a unit of liquidity is worth. Deployed on its
///         own and linked, so PositionGuard fits under the 24 KB contract size limit. Holds no state.
library PoolMath {
    using MulDiv for uint256;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    error NoPriceHistory();

    /// @notice The pool's average tick over the last TWAP_WINDOW, rounded towards -infinity.
    function twapTick(address pool) public view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        int56[] memory cum;
        try ICLPool(pool).observe(ago) returns (int56[] memory c, uint160[] memory) {
            cum = c;
        } catch {
            revert NoPriceHistory();
        }
        int56 delta = cum[1] - cum[0];
        tick = int24(delta / int56(uint56(TWAP_WINDOW)));
        if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) tick--;
    }

    /// @notice The pool's reward counter as it would read if updated now. The pool itself only brings it
    ///         up to date when touched, so a quiet pool would read as paying nothing and then, at its next
    ///         swap, as having paid everything at once. Mirrors CLPool._settleToBlock: the AERO accrued
    ///         since the last settlement is the gauge's unsettled reward share, read from the LeafVoter
    ///         (checked on Base 16.11.2026: ~3.9 AERO over 12 s on AERO/WETH CL200). If any of these
    ///         reads fails, the counter is taken as it stands rather than failing the review.
    function rewardGrowth(address pool) public view returns (uint256 growth) {
        ICLPool p = ICLPool(pool);
        growth = p.rewardGrowthGlobalX128();
        uint256 staked = p.stakedLiquidity();
        if (staked == 0 || p.lastUpdated() == block.timestamp) return growth;
        address gauge = p.gauge();
        if (gauge == address(0)) return growth;
        try ICLGauge(gauge).voter() returns (address voter) {
            try ILeafVoter(voter).projectedCumulativeRewardShare(gauge) returns (uint256 projected) {
                try ICLGauge(gauge).lastCumulativeRewardShare() returns (uint256 settled) {
                    if (projected > settled) {
                        unchecked {
                            growth += (projected - settled).mulDiv(2 ** 128, staked); // the counter may wrap, like the pool's
                        }
                    }
                } catch {}
            } catch {}
        } catch {}
    }

    /// @notice What one unit of liquidity is worth in token1, X96, for a range of ± `halfWidth` ticks
    ///         (rounded to the pool's step, at least one step) around the 30-minute average price.
    function valuePerLiquidity(address pool, int24 halfWidth, ISugarHelper sugar) public view returns (uint256) {
        int24 tick = twapTick(pool);
        int24 spacing = ICLPool(pool).tickSpacing();
        int24 half = halfWidth / spacing;
        if (half == 0) half = 1;
        int24 base = tick / spacing;
        if (tick < 0 && tick % spacing != 0) base -= 1;
        uint256 sqrtP = sugar.getSqrtRatioAtTick(tick);
        int24 lower = (base - half) * spacing;
        int24 upper = (base + 1 + half) * spacing;
        // near the ends of the price scale the range is cut at the last usable tick
        if (lower < MIN_TICK) lower = -((-MIN_TICK) / spacing) * spacing;
        if (upper > MAX_TICK) upper = (MAX_TICK / spacing) * spacing;
        uint256 sqrtA = sugar.getSqrtRatioAtTick(lower);
        uint256 sqrtB = sugar.getSqrtRatioAtTick(upper);
        // After the cut the price can sit outside the range (e.g. tick 887250, step 200, top 887200):
        // then the range holds one token only (Codex 16.11).
        uint256 lo = sqrtP < sqrtA ? sqrtA : sqrtP; // max(price, lower end)
        uint256 hi = sqrtP > sqrtB ? sqrtB : sqrtP; // min(price, upper end)
        // token1 held below the price + token0 held above it, valued in token1 at the price
        uint256 in1 = hi > sqrtA ? hi - sqrtA : 0;
        uint256 in0 = lo < sqrtB ? sqrtP.mulDiv(sqrtP, lo).mulDiv(sqrtB - lo, sqrtB) : 0;
        return in1 + in0;
    }
}
