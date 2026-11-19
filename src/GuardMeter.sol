// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ICLFactory, ICLPool, ISugarHelper} from "./interfaces/IAero.sol";
import {PoolMath} from "./lib/PoolMath.sol";

/// @title GuardMeter
/// @notice The PositionGuard's measurements of Aero (Slipstream) pools, kept apart from the guard so the
///         guard fits under the 24 KB contract size limit. Holds no funds.
///
///         For each pool it keeps two readings of the reward counter (what the pool pays) and a day of
///         hourly price snapshots (how much its price swings). From them it tells what sitting in a
///         pool earns net of the expected loss to swings, which the guard uses to leave a pool that no
///         longer pays and to move into a pool of the same two tokens that pays more.
///
///         Only the guard that created it takes pay readings; anyone may take a price snapshot, since a
///         snapshot is the pool's own 30-minute average and more of them only measure over more points.
contract GuardMeter {
    address public immutable guard;
    ICLFactory public immutable factory;
    address public immutable aero;
    ISugarHelper public immutable sugar;

    mapping(address pool => PoolMath.PayMark) public payMark;
    mapping(address pool => PoolMath.SnapLog) internal snapLog;

    error NotGuard();
    error UnknownPool();

    constructor(address factory_, address aero_, address sugar_) {
        guard = msg.sender;
        factory = ICLFactory(factory_);
        aero = aero_;
        sugar = ISugarHelper(sugar_);
    }

    /// @notice Take a new reading of the pool's reward counter (at most once per 12 hours). Guard only.
    function markPay(address pool) external {
        if (msg.sender != guard) revert NotGuard();
        PoolMath.markPay(payMark[pool], pool);
    }

    /// @notice Keep a price snapshot of a real pool of the factory (at most once an hour).
    function snap(address pool) external {
        _check(pool);
        PoolMath.snap(snapLog[pool], pool);
    }

    // ---- readings ----

    /// @notice See PoolMath.payRate.
    function payRate(address pool, int24 halfWidth) external view returns (uint256) {
        return PoolMath.payRate(payMark[pool], pool, halfWidth, sugar);
    }

    /// @notice See PoolMath.lossRate.
    function lossRate(address pool, int24 halfWidth) external view returns (uint256) {
        return PoolMath.lossRate(snapLog[pool], pool, halfWidth, sugar);
    }

    /// @notice What 1e18 of AERO is worth in `pool`'s token1; `via` (a pool of AERO and one of the
    ///         pool's tokens) is used when the pool has no AERO in it. Both must be pools of the factory.
    function aeroPrice(address pool, address via) public view returns (uint256) {
        _check(pool);
        if (via != address(0) && ICLPool(pool).token0() != aero && ICLPool(pool).token1() != aero) _check(via);
        return PoolMath.aeroPrice(pool, via, aero, sugar);
    }

    /// @notice What a staked in-range position in `pool` gains per second, share of its value scaled by
    ///         1e18: AERO paid (in token1) minus the expected loss to price swings.
    function netRate(address pool, int24 halfWidth, address via) public view returns (int256) {
        aeroPrice(pool, via); // checks both pools
        return PoolMath.netRate(payMark[pool], snapLog[pool], pool, halfWidth, via, aero, sugar);
    }

    /// @notice Variance of the pool's log price per second (1e18), zero until three snapshots.
    function priceVariance(address pool) external view returns (uint256) {
        return PoolMath.priceVariance(snapLog[pool]);
    }

    /// @notice The snapshots kept for a pool, oldest first.
    function snapsOf(address pool) external view returns (PoolMath.Snap[] memory) {
        return PoolMath.snapsOf(snapLog[pool]);
    }

    /// @notice Start of the window the pool's pay is measured over; zero while not measurable.
    function paySince(address pool) external view returns (uint64) {
        return PoolMath.paySince(payMark[pool]);
    }

    /// @notice `netRate` per day (1e18 = 100% of value) for a staked position of half-width `half` ticks,
    ///         and whether all of it was measured: a full pay window, at least three snapshots, a
    ///         range wider than one step, and a price for AERO. What is not measured is never acted on.
    function netPerDay(address pool, int24 half, int24 spacing, address via)
        external
        view
        returns (int256 net, bool measured_)
    {
        if (PoolMath.paySince(payMark[pool]) == 0 || half < spacing || PoolMath.priceVariance(snapLog[pool]) == 0) {
            return (0, false);
        }
        // the price pool may lose its 30-minute history and revert: then this is simply not measured
        try this.aeroPrice(pool, via) returns (uint256 price) {
            if (price == 0) return (0, false);
        } catch {
            return (0, false);
        }
        measured_ = true;
        net = netRate(pool, half, via) * 1 days;
    }

    /// @notice Whether a pool's pay and its swings have both been measured.
    function measured(address pool) external view returns (bool) {
        return PoolMath.measured(payMark[pool], snapLog[pool]);
    }

    /// @notice The measured alternate (with a gauge) that earns the most, if it beats `floor`; else zero.
    function bestAlternate(address[] calldata alts, int24 halfWidth, address via, int256 floor)
        external
        view
        returns (address)
    {
        return PoolMath.bestAlternate(payMark, snapLog, alts, halfWidth, via, floor);
    }

    function _check(address pool) internal view {
        ICLPool p = ICLPool(pool);
        if (factory.getPool(p.token0(), p.token1(), p.tickSpacing()) != pool) revert UnknownPool();
    }
}
