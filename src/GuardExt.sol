// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {GuardCore} from "./GuardCore.sol";
import {ICLPool, ICLGauge, IERC20, INonfungiblePositionManager} from "./interfaces/IAero.sol";

/// @title GuardExt
/// @notice The owner functions and views of PositionGuard. Only meant to run through the guard's
///         `fallback` (delegatecall), on the guard's storage and balances; called directly it works on its
///         own empty storage and holds nothing.
contract GuardExt is GuardCore {
    constructor(address npm_, address aero_, address callbackProxy_, address reactive_, address sugar_, address meter_)
        GuardCore(npm_, aero_, callbackProxy_, reactive_, sugar_, meter_)
    {}

    /// @notice One step in: take the tokens (either amount may be zero), pick the pool of the pair that
    ///         has earned the most net of price swings among `p.pool` and `p.alternates` (`p.pool` while
    ///         none is measured), swap part of the bigger side in that pool so both sides match, open a
    ///         position around the current price, stake it and guard it for the caller. The other pools
    ///         become its alternates. Whatever the pool did not take goes straight back to the caller.
    /// @dev Any ETH sent along stays in the guard and pays for the Reactive callback.
    function open(OpenParams calldata p) external payable lock returns (uint256 tokenId) {
        if (p.halfWidth == 0) revert BadWidth();
        if (p.maxLossBps >= 10_000) revert BadLimit();
        if (p.alternates.length > MAX_ALTERNATES) revert TooManyAlternates();
        (address t0, address t1) = _poolTokens(p.pool);
        // coins already on the guard (parked for others) are never part of this entry
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        _pull(t0, p.amount0);
        _pull(t1, p.amount1);
        int24 half = int24(uint24(p.halfWidth)) * ICLPool(p.pool).tickSpacing();
        address[] memory all = new address[](p.alternates.length + 1);
        all[0] = p.pool;
        for (uint256 i = 0; i < p.alternates.length; i++) {
            (address a0, address a1) = _poolTokens(p.alternates[i]);
            if (a0 != t0 || a1 != t1 || p.alternates[i] == p.pool) revert NotSamePair();
            all[i + 1] = p.alternates[i];
        }
        // pools are compared on AERO pay priced in token1: without a price for AERO the ranking means nothing
        if (p.pricePool != address(0)) meter.aeroPrice(p.pool, p.pricePool);
        else if ((all.length > 1 || p.reenter) && t0 != address(aero) && t1 != address(aero)) revert BadPricePool();
        // going back in is judged on AERO pay, which only a staked position earns (Codex 26.11)
        if (p.reenter && !p.stake) revert BadLimit();
        address pool = p.pool;
        if (all.length > 1) {
            address best = meter.bestAlternate(all, half, p.pricePool, type(int256).min);
            if (best != address(0)) pool = best;
        }
        tokenId = _enter(
            msg.sender, pool, half, t0, t1, b0, b1, p.amount0Min, p.amount1Min, p.stake, p.maxLossBps, p.graceSeconds
        );
        _settle(tokenId, all, pool, p.pricePool, p.reenter, 0);
        _sendNew(t0, msg.sender, b0);
        _sendNew(t1, msg.sender, b1);
    }

    // ---- called by the guard on itself (through its fallback), never by anyone else ----

    /// @dev Called by the guard on itself: puts a parked plan's coins into `pool` as a new position with
    ///      the plan's settings. What the range does not take goes to the owner.
    function enterParked(uint256 id, address pool) external {
        if (msg.sender != address(this)) revert NotOwner();
        Park memory k = _parked[id];
        address[] memory all = alternates[id];
        address via = _pricePool[id];
        uint16 netExit = _netExitBps[id];
        uint32 grace = _rangeWatch[id].grace;
        _unpark(id, k);
        _forget(id);
        // everything on the guard except this plan's coins
        uint256 b0 = IERC20(k.token0).balanceOf(address(this)) - k.bal0;
        uint256 b1 = IERC20(k.token1).balanceOf(address(this)) - k.bal1;
        uint256 newId = _enter(k.owner, pool, k.half, k.token0, k.token1, b0, b1, 0, 0, k.stake, k.maxLossBps, grace);
        _settle(newId, all, pool, via, true, netExit);
        _sendNew(k.token0, k.owner, b0);
        _sendNew(k.token1, k.owner, b1);
        emit Reentered(id, newId, pool);
    }

    /// @dev The guard decided a move (see PositionGuard._maybeMove); it runs here, on the guard's state.
    function moveExec(uint256 tokenId, address target, int24 half) external {
        if (msg.sender != address(this)) revert NotOwner();
        _move(tokenId, _guarded[tokenId], target, half, alternates[tokenId]);
    }

    /// @dev Closes the position into the guard and opens one of the same width around the price in
    ///      `target`, staked and guarded with the same settings. The old pool becomes an alternate.
    ///      AERO earned and whatever the new range does not take go straight to the owner.
    function _move(uint256 tokenId, Guarded memory g, address target, int24 half, address[] memory alts) internal {
        uint16 maxLoss = g.maxLossBps;
        uint16 netExit = _netExitBps[tokenId];
        uint32 grace = _rangeWatch[tokenId].grace;
        address via = _pricePool[tokenId];
        bool re = _reenterOn[tokenId];
        (address t0, address t1) = _poolTokens(target);
        // count only what this position returns, never coins that happen to sit on the guard
        uint256 b0 = IERC20(t0).balanceOf(address(this));
        uint256 b1 = IERC20(t1).balanceOf(address(this));
        uint256 bA = aero.balanceOf(address(this));
        _close(tokenId, g, address(this));
        // a position that left its range holds one token: the entry swaps half of it first (Codex 26.11)
        uint256 newId = _enter(g.owner, target, half, t0, t1, b0, b1, 0, 0, true, maxLoss, grace);
        _netExitBps[newId] = netExit;
        _pricePool[newId] = via;
        _reenterOn[newId] = re;
        for (uint256 i = 0; i < alts.length; i++) {
            if (alts[i] == target) alts[i] = g.pool;
        }
        alternates[newId] = alts;
        _sendNew(t0, g.owner, b0);
        _sendNew(t1, g.owner, b1);
        if (address(aero) != t0 && address(aero) != t1) _sendNew(address(aero), g.owner, bA);
        emit Moved(tokenId, newId, target);
    }
}
