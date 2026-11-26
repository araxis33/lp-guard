// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {GuardCore} from "./GuardCore.sol";
import {ICLPool, ICLGauge, IERC20, INonfungiblePositionManager} from "./interfaces/IAero.sol";

/// @dev Functions of GuardExt the guard calls on itself (they reach GuardExt through `fallback`).
interface IExtSelf {
    function enterParked(uint256 id, address pool) external;
    function moveExec(uint256 tokenId, address target, int24 half) external;
}

/// @title PositionGuard
/// @notice Holds users' Aero (Slipstream) liquidity positions, keeps them staked so they earn AERO, and
///         watches them on a clock run by a Reactive contract: hourly it keeps price snapshots and closes a
///         position that stayed out of range; daily it compares each position with simply holding, closes
///         one that falls behind or whose pool no longer pays for its price swings, moves one into a pool
///         of the same pair that pays more, and puts parked coins back into a pool that pays again.
///
///         Owner functions (open, deposit, take back, close, settings, views) live in GuardExt and run
///         here through `fallback` (delegatecall), on this contract's storage and balances: this contract
///         alone would not fit the 24 KB contract size limit.
///
///         The Reactive contract can only start the check and the review. Everything a close pays out goes
///         to the owner or stays parked for the owner; it can never take funds.
contract PositionGuard is GuardCore {
    /// @notice The extension that runs the owner functions on this contract's storage.
    address public immutable ext;

    constructor(
        address npm_,
        address aero_,
        address callbackProxy_,
        address reactive_,
        address sugar_,
        address meter_,
        address ext_
    ) GuardCore(npm_, aero_, callbackProxy_, reactive_, sugar_, meter_) {
        ext = ext_;
    }

    /// @notice Everything else (owner functions and views) runs in GuardExt on this contract's state.
    fallback() external payable {
        address e = ext;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), e, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            switch ok
            case 0 { revert(ptr, returndatasize()) }
            default { return(ptr, returndatasize()) }
        }
    }

    /// @notice Review one position now, without waiting for the daily run. Owner only.
    function review(uint256 tokenId) external lock {
        if (_guarded[tokenId].owner != msg.sender && _parked[tokenId].owner != msg.sender) revert NotOwner();
        _review(tokenId);
    }

    /// @notice The daily review of every guarded position, asked for by the Reactive contract's
    ///         timer. A position whose pool has no price history yet is skipped, not closed.
    function reviewByReactive(address sender_) external lock onlyServiceProvider onlyCallbackSender(sender_) {
        uint256 len = _reviewList.length;
        if (len == 0) return;
        uint256 n = len < MAX_REVIEW ? len : MAX_REVIEW;
        uint256 start = reviewCursor % len;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = _reviewList[(start + i) % len];
        }
        uint256 done;
        for (; done < n; done++) {
            if (gasleft() < GAS_PER_REVIEW + 50_000) break;
            try this.reviewOne{gas: GAS_PER_REVIEW}(ids[done]) {}
            catch {
                emit CheckFailed(ids[done]);
            }
        }
        // Next run starts at the first position this one did not reach, so every position gets its turn.
        reviewCursor = start + done;
    }

    /// @dev Called by the guard on itself so one failing position cannot stop the others.
    function reviewOne(uint256 tokenId) external {
        if (msg.sender != address(this)) revert NotOwner();
        _review(tokenId);
    }

    /// @notice The hourly check, asked for by the Reactive contract's timer: keeps a price snapshot of
    ///         each position's pool, and closes a position whose pool's 30-minute average price has
    ///         stayed outside its range for its grace period. Snapshots make `netPerDay` measurable
    ///         within hours of a deposit instead of days.
    function checkByReactive(address sender_) external lock onlyServiceProvider onlyCallbackSender(sender_) {
        uint256 len = _reviewList.length;
        if (len == 0) return;
        uint256 n = len < MAX_CHECK ? len : MAX_CHECK;
        uint256 start = checkCursor % len;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = _reviewList[(start + i) % len];
        }
        uint256 done;
        for (; done < n; done++) {
            if (gasleft() < GAS_PER_CHECK + 50_000) break;
            try this.checkOne{gas: GAS_PER_CHECK}(ids[done]) {}
            catch {
                emit CheckFailed(ids[done]);
            }
        }
        // the next check starts at the first position this one did not reach
        checkCursor = start + done;
    }

    /// @dev Called by the guard on itself so one failing position cannot stop the others.
    function checkOne(uint256 tokenId) external {
        if (msg.sender != address(this)) revert NotOwner();
        Guarded memory g = _guarded[tokenId];
        if (g.owner != address(0)) {
            _snap(g.pool);
            if (_rangeStep(tokenId, g)) return; // closed
        }
        // alternates of a position, or every pool of a parked plan
        address[] storage alts = alternates[tokenId];
        for (uint256 i = 0; i < alts.length; i++) {
            try meter.snap{gas: SNAP_GAS}(alts[i]) {} catch {}
        }
    }

    /// @dev Updates the out-of-range clock of a position and closes it when the grace period is over
    ///      and both the 30-minute average and the current price are out of range. True if closed.
    function _rangeStep(uint256 tokenId, Guarded memory g) internal returns (bool) {
        RangeWatch storage w = _rangeWatch[tokenId];
        if (w.grace == 0) return false;
        (,,,,, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        int24 avg = _twapTick(g.pool);
        if (avg >= lower && avg < upper) {
            if (w.outSince != 0) {
                w.outSince = 0;
                emit CameBack(tokenId, avg);
            }
            return false;
        }
        if (w.outSince == 0) {
            w.outSince = uint64(block.timestamp);
            emit WentOut(tokenId, avg);
            return false;
        }
        if (block.timestamp - w.outSince < w.grace) return false;
        (, int24 spot,,,,) = ICLPool(g.pool).slot0();
        int24 gap = spot > avg ? spot - avg : avg - spot;
        if (gap > MAX_SPOT_DEVIATION || (spot >= lower && spot < upper)) {
            emit CloseDeferred(tokenId, spot, avg);
            return false;
        }
        _exit(tokenId, g);
        return true;
    }

    /// @dev Claims the AERO earned so far to the owner, then compares the position with holding
    ///      and closes it if it is behind by more than the owner's limit.
    function _review(uint256 tokenId) internal {
        Guarded storage g = _guarded[tokenId];
        if (g.owner == address(0)) {
            if (_parked[tokenId].owner != address(0)) _reviewPark(tokenId);
            return;
        }
        if (g.gauge != address(0)) {
            uint256 before = aero.balanceOf(g.owner);
            uint256[] memory ids = new uint256[](1);
            ids[0] = tokenId;
            ICLGauge(g.gauge).claimEmissions(address(this), g.owner, ids);
            g.aeroPaid += aero.balanceOf(g.owner) - before;
        }
        (uint256 holdValue, uint256 positionValue, uint256 aeroValue) = _standing(tokenId);
        bool behind =
            g.maxLossBps > 0 && (positionValue + aeroValue) * 10_000 < holdValue * (10_000 - uint256(g.maxLossBps));
        uint16 netLimit = _netExitBps[tokenId];
        bool netDue;
        int256 net;
        if (!behind && netLimit > 0 && g.gauge != address(0)) {
            bool measured;
            (net, measured) = _netPerDay(tokenId);
            // 1 basis point a day = 1e14 in the 1e18 share scale
            netDue = measured && net < -int256(uint256(netLimit)) * 1e14;
            behind = netDue;
        }
        if (behind) {
            int24 avg = _twapTick(g.pool);
            (, int24 spot,,,,) = ICLPool(g.pool).slot0();
            int24 gap = spot > avg ? spot - avg : avg - spot;
            if (gap > MAX_SPOT_DEVIATION) {
                emit CloseDeferred(tokenId, spot, avg);
                behind = false;
            }
        }
        if (behind && netDue) emit NetExitDue(tokenId, net);
        emit Reviewed(tokenId, holdValue, positionValue, aeroValue, behind);
        // Readings are only needed for positions that stay; a close must fit in GAS_PER_REVIEW.
        if (behind) {
            _exit(tokenId, g);
        } else {
            _markPays(tokenId, g.pool);
            // a pool that fails to read or a mint that reverts must not undo the review
            try this.moveStep(tokenId) {} catch {}
        }
    }

    /// @dev Reads the reward counter and keeps a price snapshot for the current pool and its alternates.
    function _markPays(uint256 tokenId, address pool) internal {
        _markPay(pool);
        _snap(pool);
        address[] storage alts = alternates[tokenId];
        for (uint256 i = 0; i < alts.length; i++) {
            _markPay(alts[i]);
            // a pool too new to have 30 minutes of prices must not stop the review of this position
            try meter.snap(alts[i]) {} catch {}
        }
    }

    /// @notice Called by a pool during `_swap` to be paid. Only the pool the guard is swapping in
    ///         right now gets anything, and only the amount it is owed.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != swapPool || msg.sender == address(0)) revert NotSwapPool();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (!IERC20(tokenIn).transfer(msg.sender, owed)) revert TransferFailed();
    }

    /// @dev Only NFTs the guard is taking in itself (a gauge returning a position, or a mint) are
    ///      accepted: one sent here any other way would have no owner on record and could not be withdrawn.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(npm) || nftExpected == 0) revert NotGuarded();
        return this.onERC721Received.selector;
    }

    // ---- owner functions and views ----

    /// @notice Hand a position to the guard. The caller must own it and have approved the guard.
    ///         The review compares against what the position holds at this moment.
    /// @param stake true to stake it in the pool's gauge (earns AERO), false to hold it unstaked (earns fees).
    /// @param graceSeconds how long the price must stay outside the position's range before it is
    ///        closed automatically. Zero turns the automatic close off.
    /// @dev Any ETH sent along stays in the guard and pays for the Reactive callback.
    function deposit(uint256 tokenId, bool stake, uint32 graceSeconds) external payable lock {
        if (_parked[tokenId].owner != address(0)) revert IsParked();
        npm.transferFrom(msg.sender, address(this), tokenId);
        (uint160 sqrtP,,,,,) = ICLPool(_poolOf(tokenId)).slot0();
        (uint256 a0, uint256 a1) = sugar.principal(address(npm), tokenId, sqrtP);
        _record(tokenId, 0, a0, a1);
        _guard(tokenId, msg.sender, stake, graceSeconds);
    }

    /// @notice Keep (true) or send out (false) the coins when the guard closes this position by itself.
    function setReenter(uint256 tokenId, bool on) external {
        Guarded storage g = _guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (on && g.gauge == address(0)) revert BadLimit();
        if (on && _pricePool[tokenId] == address(0)) {
            (address t0, address t1) = _poolTokens(g.pool);
            if (t0 != address(aero) && t1 != address(aero)) revert BadPricePool();
        }
        _reenterOn[tokenId] = on;
    }

    /// @notice Take parked coins back, at any moment. Needs nothing but the two transfers.
    function takeParked(uint256 id) external lock {
        Park memory k = _parked[id];
        if (k.owner != msg.sender) revert NotOwner();
        _unpark(id, k);
        _forget(id);
        if (k.bal0 > 0 && !IERC20(k.token0).transfer(k.owner, k.bal0)) revert TransferFailed();
        if (k.bal1 > 0 && !IERC20(k.token1).transfer(k.owner, k.bal1)) revert TransferFailed();
        emit Unparked(id, k.owner, k.bal0, k.bal1);
    }

    /// @notice Take the position back as it is, with any AERO it earned.
    function withdraw(uint256 tokenId) external lock {
        Guarded memory g = _guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        delete _guarded[tokenId];
        _forget(tokenId);
        _unstake(tokenId, g, g.owner);
        npm.transferFrom(address(this), g.owner, tokenId);
        emit Withdrawn(tokenId, g.owner);
    }

    /// @notice Set how far behind simply holding the position may fall before the daily review
    ///         closes it, in basis points (100 = 1%). Zero: the review only reports, never closes.
    function setMaxLoss(uint256 tokenId, uint16 maxLossBps) external {
        Guarded storage g = _guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (maxLossBps >= 10_000) revert BadLimit();
        g.maxLossBps = maxLossBps;
        emit MaxLossSet(tokenId, maxLossBps);
    }

    /// @notice Name up to three other pools of the same two tokens (for example the same pair with a
    ///         different price step) that this position may be moved into when they pay more.
    ///         An empty list turns moving off.
    function setAlternates(uint256 tokenId, address[] calldata pools) external {
        Guarded storage g = _guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (pools.length > MAX_ALTERNATES) revert TooManyAlternates();
        (address t0, address t1) = _poolTokens(g.pool);
        for (uint256 i = 0; i < pools.length; i++) {
            (address a0, address a1) = _poolTokens(pools[i]);
            if (a0 != t0 || a1 != t1 || pools[i] == g.pool) revert NotSamePair();
        }
        alternates[tokenId] = pools;
        emit AlternatesSet(tokenId, pools);
    }

    /// @notice Name the pool that prices AERO for this position when its own pool has no AERO in it:
    ///         a pool of AERO and one of the position's two tokens (for WETH/USDC, AERO/WETH or
    ///         AERO/USDC). Owner only, so nobody can point the guard at a thin pool whose price is
    ///         cheap to move. Zero turns it off.
    function setPricePool(uint256 tokenId, address via) external {
        Guarded storage g = _guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (via != address(0)) {
            meter.aeroPrice(g.pool, via); // reverts unless it prices AERO for this pool
        } else if (_reenterOn[tokenId]) {
            // parked coins go back in on AERO pay: a pair without AERO must keep its price (Codex 26.11)
            (address t0, address t1) = _poolTokens(g.pool);
            if (t0 != address(aero) && t1 != address(aero)) revert BadPricePool();
        }
        _pricePool[tokenId] = via;
        emit PricePoolSet(tokenId, via);
    }

    /// @notice Close at the review when sitting in the pool no longer pays: the AERO the pool pays
    ///         (priced in token1) minus what the position is expected to lose to price swings
    ///         (`netRate`) is below minus `bpsPerDay` basis points of its value a day. Owner only.
    ///         Zero turns it off. Only staked positions earn AERO, so it only acts on those, and only
    ///         once the pool's pay, price swings and AERO price have all been measured.
    function setNetExit(uint256 tokenId, uint16 bpsPerDay) external {
        Guarded storage g = _guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (bpsPerDay >= 10_000) revert BadLimit();
        _netExitBps[tokenId] = bpsPerDay;
        emit NetExitSet(tokenId, bpsPerDay);
    }

    /// @notice Close the position: unstake, remove all liquidity, and send both tokens, the fees
    ///         and the AERO to the owner. The empty NFT goes back to the owner as well.
    function close(uint256 tokenId) external lock {
        Guarded memory g = _guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (msg.sender != g.owner) revert NotOwner();
        _close(tokenId, g, g.owner);
    }

    /// @notice AERO the position has earned in the gauge and not yet claimed.
    function pendingAero(uint256 tokenId) external view returns (uint256) {
        Guarded memory g = _guarded[tokenId];
        if (g.gauge == address(0)) return 0;
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        return ICLGauge(g.gauge).earned(address(this), ids);
    }

    /// @notice The review's numbers for a position right now, without acting on them.
    ///         All in the pool's token1 at the 30-minute average price.
    function standing(uint256 tokenId)
        public
        view
        returns (uint256 holdValue, uint256 positionValue, uint256 aeroValue)
    {
        return _standing(tokenId);
    }

    /// @notice The other pools this position may be moved into.
    function alternatesOf(uint256 tokenId) external view returns (address[] memory) {
        return alternates[tokenId];
    }

    /// @notice `netRate` for this position's own pool and range, per day (1e18 = 100% of its value),
    ///         and whether all of it was measured: a staked position, a full pay window, at least
    ///         three price snapshots, and a price for AERO. A reading that is not measured is never
    ///         acted on, so a pool is not left just because the guard has not watched it long enough.
    ///         Like `payRate`, it describes a position that sits in range: one out of range earns no
    ///         AERO whatever this says, and leaving it is the job of the out-of-range close (graceSeconds).
    function netPerDay(uint256 tokenId) public view returns (int256 net, bool measured) {
        Guarded storage g = _guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (g.gauge == address(0)) return (0, false);
        (,,,, int24 spacing, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        return meter.netPerDay(g.pool, (upper - lower) / 2, spacing, _pricePool[tokenId]);
    }

    /// @notice Positions the daily review goes through.
    function reviewCount() external view returns (uint256) {
        return _reviewList.length;
    }

    /// @dev The daily look at a parked plan: measure its pools, and go back in when the same pool has
    ///      earned more than REENTER_FLOOR net of swings at two reviews at least MOVE_WAIT apart.
    function _reviewPark(uint256 id) internal {
        Park memory k = _parked[id];
        address[] memory pools = alternates[id];
        for (uint256 i = 0; i < pools.length; i++) {
            _markPay(pools[i]);
            try meter.snap(pools[i]) {} catch {}
        }
        address best;
        try meter.bestAlternate(pools, k.half, _pricePool[id], REENTER_FLOOR) returns (address b) {
            best = b;
        } catch {}
        if (best == address(0)) {
            delete _moveVote[id];
            return;
        }
        if (_moveVote[id] != best) {
            _moveVote[id] = best;
            moveVoteAt[id] = uint64(block.timestamp);
            return;
        }
        if (block.timestamp < moveVoteAt[id] + MOVE_WAIT) return;
        // a failed entry rolls back whole and waits for a fresh pair of readings
        try IExtSelf(address(this)).enterParked(id, best) {}
        catch {
            moveVoteAt[id] = uint64(block.timestamp);
            emit ReenterFailed(id);
        }
    }

    /// @dev Moves a staked position into the alternate pool that has earned the most net of price
    ///      swings, when it beats the current pool by MOVE_MARGIN at two reviews in a row and neither
    ///      pool's price is being pushed right now. Readings only: no forecast, nothing unmeasured.
    /// @dev Called by the guard on itself from the review (see `_maybeMove`).
    function moveStep(uint256 tokenId) external {
        if (msg.sender != address(this)) revert NotOwner();
        _maybeMove(tokenId);
    }

    function _maybeMove(uint256 tokenId) internal {
        Guarded memory g = _guarded[tokenId];
        address[] memory alts = alternates[tokenId];
        if (alts.length == 0 || g.gauge == address(0)) return;
        // only on a full reading of the current pool: pay, swings, a price for AERO, a real width
        (, bool ok) = _netPerDay(tokenId);
        if (!ok) return;
        (address target, int24 half) = _moveTarget(tokenId, g.pool, alts);
        if (target == address(0)) {
            delete _moveVote[tokenId];
            return;
        }
        if (_moveVote[tokenId] != target) {
            _moveVote[tokenId] = target;
            moveVoteAt[tokenId] = uint64(block.timestamp);
            return;
        }
        if (block.timestamp < moveVoteAt[tokenId] + MOVE_WAIT) return;
        // both pools trade the same pair: their averages must agree, and neither may be pushed now
        int24 d = _twapTick(g.pool) - _twapTick(target);
        if (_pushed(g.pool) || _pushed(target) || d > MAX_SPOT_DEVIATION || -d > MAX_SPOT_DEVIATION) return;
        IExtSelf(address(this)).moveExec(tokenId, target, half);
    }

    /// @dev The alternate that beats the current pool by MOVE_MARGIN (zero if none), and the half width.
    function _moveTarget(uint256 tokenId, address pool, address[] memory alts)
        internal
        view
        returns (address target, int24 half)
    {
        (,,,,, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        half = (upper - lower) / 2;
        address via = _pricePool[tokenId];
        target = meter.bestAlternate(alts, half, via, meter.netRate(pool, half, via) + int256(MOVE_MARGIN));
    }

    // ---- storage getters (here only, so GuardExt stays under the size limit) ----

    function guarded(uint256 id) external view returns (Guarded memory) {
        return _guarded[id];
    }

    function parked(uint256 id) external view returns (Park memory) {
        return _parked[id];
    }

    function parkedTotal(address token) external view returns (uint256) {
        return _parkedTotal[token];
    }

    function reviewList(uint256 i) external view returns (uint256) {
        return _reviewList[i];
    }

    function pricePool(uint256 id) external view returns (address) {
        return _pricePool[id];
    }

    function rangeWatch(uint256 id) external view returns (RangeWatch memory) {
        return _rangeWatch[id];
    }

    function moveVote(uint256 id) external view returns (address) {
        return _moveVote[id];
    }

    function netExitBps(uint256 id) external view returns (uint16) {
        return _netExitBps[id];
    }

    function reenterOn(uint256 id) external view returns (bool) {
        return _reenterOn[id];
    }
}
