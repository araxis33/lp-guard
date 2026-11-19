// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ICLPool, ICLGauge, ILeafVoter, ISugarHelper} from "../interfaces/IAero.sol";
import {MulDiv} from "./MulDiv.sol";

/// @title PoolMath
/// @notice Readings of an Aero (Slipstream) pool that PositionGuard needs: its average price, its
///         reward counter brought up to date, and what a unit of liquidity is worth. Deployed on its
///         own and linked, so PositionGuard fits under the 24 KB contract size limit. Holds no state.
interface INetRate {
    function netRate(address pool, int24 halfWidth, address via) external view returns (int256);
}

library PoolMath {
    using MulDiv for uint256;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint256 internal constant Q96 = 2 ** 96;
    /// @dev Kept snapshots per pool, and the shortest gap between two (see PositionGuard).
    uint256 internal constant SNAP_SLOTS = 24;
    uint64 internal constant SNAP_GAP = 1 hours;
    /// @dev Shortest stretch of time a pool's pay is measured over.
    uint64 internal constant MIN_PAY_WINDOW = 12 hours;
    /// @dev (ln 1.0001)^2 scaled by 1e18: one tick of price movement as a squared log return.
    uint256 internal constant TICK_VAR_1E18 = 9_999_000_092;

    /// @dev Two readings of a pool's reward counter (AERO paid per unit of staked liquidity, X128),
    ///      so its pay can be measured over a real stretch of time even right after a new reading.
    struct PayMark {
        uint256 growth; // last reading
        uint64 readAt;
        uint256 prevGrowth; // the reading before it
        uint64 prevReadAt;
    }

    struct Snap {
        uint64 at;
        int24 tick; // the pool's 30-minute average tick at `at`
    }

    struct SnapLog {
        uint8 next; // slot the next snapshot goes into
        uint8 count; // filled slots, up to SNAP_SLOTS
        Snap[24] snaps;
    }

    /// @notice A new reading of a pool's reward counter was taken.
    event PayMarked(address indexed pool, uint256 growth);
    /// @notice A new price snapshot of a pool was kept.
    event Snapped(address indexed pool, int24 averageTick);

    error NoPriceHistory();
    error BadPricePool();

    // ---- readings kept by the guard (storage passed in) ----

    /// @notice Takes a new reading of the pool's reward counter, at most once per MIN_PAY_WINDOW,
    ///         keeping the previous one so `payRate` always has a full window to measure over.
    function markPay(PayMark storage m, address pool) public {
        if (m.readAt != 0 && block.timestamp - m.readAt < MIN_PAY_WINDOW) return;
        uint256 growth = rewardGrowth(pool);
        if (growth < m.growth) growth = m.growth; // a failed voter read never moves the mark back
        m.prevGrowth = m.growth;
        m.prevReadAt = m.readAt;
        m.growth = growth;
        m.readAt = uint64(block.timestamp);
        emit PayMarked(pool, growth);
    }

    /// @notice Keeps the pool's 30-minute average tick, at most once per SNAP_GAP, overwriting the oldest.
    function snap(SnapLog storage l, address pool) public {
        if (l.count > 0) {
            uint256 last = (uint256(l.next) + SNAP_SLOTS - 1) % SNAP_SLOTS;
            if (block.timestamp - l.snaps[last].at < SNAP_GAP) return;
        }
        int24 tick = twapTick(pool);
        l.snaps[l.next] = Snap({at: uint64(block.timestamp), tick: tick});
        l.next = uint8((uint256(l.next) + 1) % SNAP_SLOTS);
        if (l.count < SNAP_SLOTS) l.count++;
        emit Snapped(pool, tick);
    }

    /// @notice Variance of the pool's log price per second, scaled by 1e18, from the snapshots kept.
    ///         Zero until there are at least three snapshots.
    function priceVariance(SnapLog storage l) public view returns (uint256) {
        uint256 n = l.count;
        if (n < 3) return 0;
        uint256 first = (uint256(l.next) + SNAP_SLOTS - n) % SNAP_SLOTS;
        uint256 sumSq;
        Snap memory prev = l.snaps[first];
        for (uint256 i = 1; i < n; i++) {
            Snap memory cur = l.snaps[(first + i) % SNAP_SLOTS];
            int256 d = int256(cur.tick) - int256(prev.tick);
            sumSq += uint256(d * d);
            prev = cur;
        }
        uint256 span = uint256(prev.at) - uint256(l.snaps[first].at);
        return sumSq * TICK_VAR_1E18 / span;
    }

    /// @notice The snapshots kept, oldest first.
    function snapsOf(SnapLog storage l) public view returns (Snap[] memory out) {
        uint256 n = l.count;
        out = new Snap[](n);
        uint256 first = (uint256(l.next) + SNAP_SLOTS - n) % SNAP_SLOTS;
        for (uint256 i = 0; i < n; i++) {
            out[i] = l.snaps[(first + i) % SNAP_SLOTS];
        }
    }

    /// @notice Start of the pay window `payRate` measures over: the last reading once it is at least
    ///         MIN_PAY_WINDOW old, otherwise the one before it. Zero: not measurable yet.
    function paySince(PayMark storage m) public view returns (uint64) {
        return block.timestamp - m.readAt >= MIN_PAY_WINDOW ? m.readAt : m.prevReadAt;
    }

    /// @notice AERO a pool has been paying per second to a staked in-range position worth 1e18 of
    ///         token1, range ± `halfWidth` ticks. Zero until a full pay window has passed.
    /// @dev A mark includes the AERO accrued but not yet settled at that moment; if the voter can't be
    ///      read now, the counter alone can sit below it until the pool settles. Read that as no pay
    ///      measured rather than as a wrap (Codex 16.11).
    function payRate(PayMark storage m, address pool, int24 halfWidth, ISugarHelper sugar)
        public
        view
        returns (uint256)
    {
        (uint256 base, uint64 since) = block.timestamp - m.readAt >= MIN_PAY_WINDOW
            ? (m.growth, m.readAt)
            : (m.prevGrowth, m.prevReadAt);
        if (since == 0) return 0;
        uint256 current = rewardGrowth(pool);
        uint256 grown = current > base ? current - base : 0;
        uint256 perValue = grown.mulDiv(1e18, valuePerLiquidity(pool, halfWidth, sugar)).mulDiv(Q96, 2 ** 128);
        return perValue / (block.timestamp - since);
    }

    /// @notice Expected loss to price swings per second, share of value scaled by 1e18, for ± `halfWidth`
    ///         ticks (loss-versus-rebalancing: variance / 4 x sqrt(price) / value per liquidity).
    ///         Zero until there are at least three snapshots.
    function lossRate(SnapLog storage l, address pool, int24 halfWidth, ISugarHelper sugar)
        public
        view
        returns (uint256)
    {
        uint256 variance = priceVariance(l);
        if (variance == 0) return 0;
        uint256 sqrtP = sugar.getSqrtRatioAtTick(twapTick(pool));
        return (variance / 4).mulDiv(sqrtP, valuePerLiquidity(pool, halfWidth, sugar));
    }

    /// @notice What 1e18 of AERO is worth in `pool`'s token1 (raw units), at 30-minute average prices:
    ///         from the pool itself when AERO is one of its tokens, otherwise through `via`, a pool of
    ///         AERO and one of `pool`'s two tokens. Zero when there is no way to price it.
    ///         Both pools must already be checked as real pools by the caller.
    function aeroPrice(address pool, address via, address aero, ISugarHelper sugar) public view returns (uint256) {
        address t0 = ICLPool(pool).token0();
        address t1 = ICLPool(pool).token1();
        if (t1 == aero) return 1e18;
        if (t0 == aero) return _in1(1e18, sugar.getSqrtRatioAtTick(twapTick(pool)));
        if (via == address(0)) return 0;
        address v0 = ICLPool(via).token0();
        address v1 = ICLPool(via).token1();
        uint160 sv = sugar.getSqrtRatioAtTick(twapTick(via));
        address shared;
        uint256 inShared; // 1e18 AERO in the shared token
        if (v0 == aero) {
            (shared, inShared) = (v1, _in1(1e18, sv));
        } else if (v1 == aero) {
            (shared, inShared) = (v0, uint256(1e18).mulDiv(Q96, sv).mulDiv(Q96, sv));
        } else {
            revert BadPricePool();
        }
        if (shared == t1) return inShared;
        if (shared == t0) return _in1(inShared, sugar.getSqrtRatioAtTick(twapTick(pool)));
        revert BadPricePool();
    }

    /// @notice Whether a pool's pay and its price swings have both been measured.
    function measured(PayMark storage m, SnapLog storage l) public view returns (bool) {
        return paySince(m) != 0 && priceVariance(l) != 0;
    }

    /// @notice Pay (AERO priced in token1) minus expected loss to swings, per second, share of value 1e18.
    function netRate(
        PayMark storage m,
        SnapLog storage l,
        address pool,
        int24 halfWidth,
        address via,
        address aero,
        ISugarHelper sugar
    ) public view returns (int256) {
        uint256 pay = payRate(m, pool, halfWidth, sugar).mulDiv(aeroPrice(pool, via, aero, sugar), 1e18);
        return int256(pay) - int256(lossRate(l, pool, halfWidth, sugar));
    }

    /// @notice The measured alternate pool (with a gauge) that earns the most net of swings, if it beats
    ///         `floor`; zero otherwise. A pool whose reading fails is skipped.
    function bestAlternate(
        mapping(address => PayMark) storage marks,
        mapping(address => SnapLog) storage logs,
        address[] memory alts,
        int24 halfWidth,
        address via,
        int256 floor
    ) public view returns (address target) {
        for (uint256 i = 0; i < alts.length; i++) {
            address a = alts[i];
            if (!measured(marks[a], logs[a]) || ICLPool(a).gauge() == address(0)) continue;
            // through the guard's own view, so one pool that fails to read does not stop the review
            try INetRate(address(this)).netRate(a, halfWidth, via) returns (int256 n) {
                if (n > floor) (floor, target) = (n, a);
            } catch {}
        }
    }

    function _in1(uint256 amount0, uint160 sqrtP) private pure returns (uint256) {
        return amount0.mulDiv(sqrtP, Q96).mulDiv(sqrtP, Q96);
    }

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
