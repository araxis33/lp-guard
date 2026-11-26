// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {INonfungiblePositionManager, ICLFactory, ICLPool, ICLGauge, IERC20, ISugarHelper} from "./interfaces/IAero.sol";
import {MulDiv} from "./lib/MulDiv.sol";
import {PoolMath} from "./lib/PoolMath.sol";
import {GuardMeter} from "./GuardMeter.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// @title GuardCore: storage and shared internals of PositionGuard and GuardExt.
/// @dev PositionGuard and GuardExt add no storage of their own, so both see the same layout.
/// Original description of the guard:
/// @notice Holds a user's Aero (Slipstream) liquidity position, keeps it staked so it earns AERO,
///         and can close it and send everything back to the user when told to.
///
///         Once a day it also reviews every position against simply holding: it claims the AERO
///         earned so far and sends it to the owner, then compares what the position is worth now,
///         plus all the AERO it has paid, with what the tokens put in would be worth if they had
///         just been held. If the position is behind by more than the owner's limit, it is closed
///         and everything goes back to the owner. Prices are 30-minute pool averages, so a single
///         trade cannot push a review into a close.
///
///         Who can do what:
///         - the position's owner: open one in a single step (`open`) or hand in an existing one
///           (`deposit`), take it back untouched, close it, set its loss limit, review it now;
///         - the Reactive contract (through the callback proxy): close it, or run the daily review.
///           Everything from a close goes to the owner, so the worst it can do is close a position
///           early. It can never take funds. Nobody else can do anything.
/// @dev The guard's own exit swap, called on itself so a failed swap can be skipped.
interface ISwapOut {
    function swapOut(address pool, bool zeroForOne, uint256 amountIn) external;
}

abstract contract GuardCore is AbstractCallback {
    using MulDiv for uint256;

    INonfungiblePositionManager public immutable npm;
    IERC20 public immutable aero;
    ISugarHelper public immutable sugar;
    /// @notice The guard's measurements of pools (pay, price swings), created with the guard.
    GuardMeter public immutable meter;

    /// @notice Length of the price average used by a review.
    uint32 public constant TWAP_WINDOW = 30 minutes;
    /// @notice Most positions one review call goes through, so it fits in one callback.
    uint256 public constant MAX_REVIEW = 2;
    /// @notice Gas each position may use in the daily review, so one costly position (for example
    ///         one holding a token that burns gas on transfer) cannot starve the others. A close by
    ///         the net rule measures pay, swings and the AERO price first: ~1.1M on Base (17.11),
    ///         a move into a better pool from one token (swap + mint) ~2.93M and going back in ~2.05M
    ///         (fork, 26.11): 3.2M each. Two fit the Reactive contract's REVIEW_GAS of 6M when neither
    ///         moves; after a move the next position waits for the next run (the cursor stops there).
    uint256 public constant GAS_PER_REVIEW = 3_200_000;
    /// @notice A review closes only while the current price is within this many ticks (~1%) of the
    ///         30-minute average; otherwise someone may be moving the price to profit from the
    ///         close, and the close waits for the next review.
    int24 public constant MAX_SPOT_DEVIATION = 100;
    uint256 internal constant Q96 = 2 ** 96;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    struct Guarded {
        address owner;
        address gauge; // zero when the position is held unstaked
        address pool;
        uint16 maxLossBps; // close when behind holding by more than this; 0 = never by review
        uint128 entry0; // token0 that went into the position
        uint128 entry1; // token1 that went into the position
        uint256 aeroPaid; // AERO already sent to the owner by reviews
    }

    mapping(uint256 tokenId => Guarded) internal _guarded;
    uint256[] internal _reviewList;
    uint256 internal reviewCursor; // where the next daily run starts
    mapping(uint256 tokenId => uint256) internal reviewSlot; // index + 1; 0 = not listed

    /// @notice Most other pools an owner may name for a position to move into.
    uint256 public constant MAX_ALTERNATES = 3;
    /// @dev Other pools of the same two tokens the owner allows this position to move into.
    mapping(uint256 tokenId => address[]) internal alternates;
    /// @notice For a pool without AERO in it: the pool the owner named to price AERO (AERO paired
    ///         with one of the position's two tokens). Zero when not set.
    mapping(uint256 tokenId => address) internal _pricePool;

    /// @dev Per position: how long the price may stay out of range before the hourly check closes it
    ///      (0 = never), and since when it has been out (0 = inside at the last check).
    struct RangeWatch {
        uint32 grace;
        uint64 outSince;
    }

    mapping(uint256 tokenId => RangeWatch) internal _rangeWatch;
    /// @notice Most positions one hourly check goes through, so it fits in one callback.
    uint256 public constant MAX_CHECK = 2;
    /// @notice Gas each position may use in the hourly check. A close that also swaps into the exit
    ///         token takes ~1.3-1.5M (fork, 26.11): 2M leaves the swap room. A plain check is ~0.2M, so two
    ///         fit the Reactive CHECK_GAS of 3M; after a close the next position waits for the next hour.
    uint256 public constant GAS_PER_CHECK = 2_000_000;
    uint256 internal checkCursor;

    /// @notice The hourly check saw the price leave a position's range (30-minute average tick).
    event WentOut(uint256 indexed tokenId, int24 averageTick);
    /// @notice The price came back into the range before the grace period ran out.
    event CameBack(uint256 indexed tokenId, int24 averageTick);
    /// @notice How much more an alternate pool must earn than the current one, net of swings, before
    ///         the position moves: 5 basis points of its value a day (1e18 = 100%, per second).
    uint256 public constant MOVE_MARGIN = uint256(5e14) / 1 days;
    /// @dev Per position: the alternate pool the last review found better. A move happens only when
    ///      two reviews in a row (two days) point at the same pool.
    mapping(uint256 tokenId => address) internal _moveVote;
    mapping(uint256 tokenId => uint64) internal moveVoteAt;
    /// @notice Least time between the two reviews that must agree before a move.
    uint64 public constant MOVE_WAIT = 20 hours;
    /// @notice The review moved a position into a pool that earns more. Coins that did not fit the
    ///         new range at the moment of the move went straight to the owner.
    event Moved(uint256 indexed fromTokenId, uint256 indexed toTokenId, address indexed pool);

    /// @notice A position's hourly check reverted or ran out of its gas; it is tried again next hour.
    event CheckFailed(uint256 indexed tokenId);
    /// @dev Gas for each alternate pool's snapshot in the hourly check.
    uint256 internal constant SNAP_GAS = 120_000;

    /// @notice Most positions and parked plans on the guard at once, so the daily run (two per callback)
    ///         reaches each of them at least every other day.
    uint256 public constant MAX_LISTED = 4;
    /// @notice Least a pool must earn net of price swings before parked coins go back in: 10 basis
    ///         points of their value a day (1e18 = 100%, per second), so a week pays for the swap twice.
    int256 public constant REENTER_FLOOR = int256(uint256(1e15) / 1 days);
    /// @notice Per position (and its parked plan): when the guard closes it by itself, keep the coins
    ///         here and put them back into the best pool once one pays again, instead of sending them out.
    mapping(uint256 id => bool) internal _reenterOn;

    /// @dev Coins of a position the guard closed by itself, waiting to go back into a pool. The id is the
    ///      closed position's NFT id; the plan keeps its settings (alternates = every pool it may go to).
    struct Park {
        address owner;
        uint64 at; // when the coins were parked
        address token0;
        address token1;
        uint128 bal0;
        uint128 bal1;
        int24 half; // half the range width in ticks
        uint16 maxLossBps;
        bool stake;
    }

    mapping(uint256 id => Park) internal _parked;
    /// @notice All parked coins of a token on the guard; its balance never drops below this.
    mapping(address token => uint256) internal _parkedTotal;
    /// @dev Per position: the token everything is turned into when it is closed (for example USDC, so
    ///      a falling coin is not held after the exit). Zero: both tokens as they come out.
    mapping(uint256 id => address) internal _exitToken;
    /// @notice The exit swap into the exit token failed (price being pushed): the two tokens were kept.
    event ExitSwapFailed(uint256 indexed id);

    /// @notice The guard closed a position by itself and kept its coins for the owner.
    event Parked(uint256 indexed id, address indexed owner, uint256 amount0, uint256 amount1);
    /// @notice The owner took the parked coins back.
    event Unparked(uint256 indexed id, address indexed owner, uint256 amount0, uint256 amount1);
    /// @notice Parked coins went back into `pool` as position `newId`.
    event Reentered(uint256 indexed id, uint256 indexed newId, address indexed pool);
    /// @notice Going back in failed (price moved, pool reverted); tried again after another wait.
    event ReenterFailed(uint256 indexed id);

    error Full();
    error Pushed();
    error IsParked();

    /// @dev Set while an owner or Reactive entry point runs, so nothing can call back into custody.
    bool internal transient locked;

    modifier lock() {
        if (locked) revert NotOwner();
        locked = true;
        _;
        locked = false;
    }

    /// @notice Per position: the review closes it when the pool's pay minus its expected loss to
    ///         price swings falls below minus this many basis points of its value a day. 0 = off.
    mapping(uint256 tokenId => uint16) internal _netExitBps;
    event NetExitSet(uint256 indexed tokenId, uint16 bpsPerDay);
    /// @notice The review closed a position because its pool no longer pays for the swings.
    ///         `netPerDay` is a share of the position's value a day, 1e18 = 100%.
    event NetExitDue(uint256 indexed tokenId, int256 netPerDay);

    event Deposited(uint256 indexed tokenId, address indexed owner, address gauge);
    event PricePoolSet(uint256 indexed tokenId, address pricePool);
    event Withdrawn(uint256 indexed tokenId, address indexed owner);
    event Closed(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed by,
        uint256 amount0,
        uint256 amount1,
        uint256 aeroPaid
    );
    /// @notice One review. All values are in the pool's token1 at the 30-minute average price.
    /// @param holdValue what the tokens put in would be worth if simply held
    /// @param positionValue what the position is worth now (its tokens plus unclaimed fees)
    /// @param aeroValue the AERO paid to the owner so far (zero if AERO has no price in this pool)
    event Reviewed(uint256 indexed tokenId, uint256 holdValue, uint256 positionValue, uint256 aeroValue, bool closed);
    event MaxLossSet(uint256 indexed tokenId, uint16 maxLossBps);
    /// @notice The review wanted to close, but the current price was too far from the average.
    event CloseDeferred(uint256 indexed tokenId, int24 spotTick, int24 averageTick);
    event AlternatesSet(uint256 indexed tokenId, address[] pools);

    error NotOwner();
    error NotGuarded();
    error UnknownPool();
    error BadWidth();
    error BadSplit();
    error BadSwapPool();
    error TooLittleReceived();
    error NotSwapPool();
    error BadLimit();
    error NoPriceHistory();
    error TooManyAlternates();
    error NotSamePair();
    error BadPricePool();

    /// @notice One swap of the payment token into one of the pool's tokens.
    struct SwapLeg {
        address pool; // an Aero Slipstream pool of tokenIn and the target token
        uint256 amountIn; // how much tokenIn to swap
        uint256 minOut; // revert if the swap gives less than this
    }

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @dev Set only while the guard itself takes in a position NFT (see onERC721Received).
    uint256 internal transient nftExpected;

    /// @dev The pool the guard is swapping in right now; only it may ask to be paid.
    address internal swapPool;

    // TransferFailed() comes from AbstractPayer (via AbstractCallback).

    /// @notice What `open` needs. The range is placed around the chosen pool's current price.
    struct OpenParams {
        address pool; // an Aero Slipstream pool; checked against the factory; the choice when nothing is measured
        uint256 amount0; // token0 to put in (may be zero: the guard swaps part of token1 for it)
        uint256 amount1; // token1 to put in (may be zero)
        uint16 halfWidth; // range = current price ± halfWidth tick spacings of `pool` (at least 1)
        uint256 amount0Min; // slippage guard on the mint: least token0 that must go in
        uint256 amount1Min; // slippage guard on the mint: least token1 that must go in
        bool stake; // stake in the gauge to earn AERO
        uint32 graceSeconds; // automatic close after this long out of range; 0 = off
        uint16 maxLossBps; // daily review closes when behind holding by more than this; 0 = off
        address[] alternates; // other pools of the same pair: the guard opens in the one that earns most
        address pricePool; // pool of AERO and one of the pair's tokens; needed with alternates when AERO is not in the pair
        bool reenter; // keep coins after an automatic close and go back in when a pool pays again
        address exitToken; // one of the pair's tokens everything is turned into on a close (e.g. USDC); 0 = both
    }

    /// @param callbackProxy_ Reactive's callback proxy on this chain.
    /// @param reactive_ The Reactive contract allowed to ask for a close or a review.
    /// @param sugar_ Aero's SugarHelper, used to value positions.
    /// @param meter_ The pool measurements (deployed first, shared by the guard and its extension).
    constructor(address npm_, address aero_, address callbackProxy_, address reactive_, address sugar_, address meter_)
        AbstractCallback(IPayable(payable(callbackProxy_)), reactive_)
    {
        npm = INonfungiblePositionManager(npm_);
        aero = IERC20(aero_);
        sugar = ISugarHelper(sugar_);
        meter = GuardMeter(meter_);
    }

    // ---- shared internals ----

    /// @dev Closes and sends everything to `to` (the owner, or the guard itself when `_move` reopens).
    function _close(uint256 tokenId, Guarded memory g, address to) internal {
        delete _guarded[tokenId];
        _forget(tokenId);
        _empty(tokenId, g, to, to);
    }

    /// @dev A close the guard decides by itself: with re-entry on, the coins stay here as a parked plan
    ///      that keeps the position's settings (its pool joins the alternates); AERO still goes to the owner.
    ///      Either way the coins are first turned into the position's exit token when it has one.
    function _exit(uint256 tokenId, Guarded memory g) internal {
        if (!_reenterOn[tokenId]) return _closeOut(tokenId, g);
        address safe = _exitToken[tokenId];
        delete _guarded[tokenId];
        delete _moveVote[tokenId];
        delete moveVoteAt[tokenId];
        _rangeWatch[tokenId].outSince = 0;
        (,, address t0, address t1,, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        (uint256 a0, uint256 a1) = _cashOut(tokenId, g, t0, t1, safe);
        alternates[tokenId].push(g.pool);
        _parked[tokenId] = Park({
            owner: g.owner,
            at: uint64(block.timestamp),
            token0: t0,
            token1: t1,
            bal0: uint128(a0),
            bal1: uint128(a1),
            half: (upper - lower) / 2,
            maxLossBps: g.maxLossBps,
            stake: g.gauge != address(0)
        });
        _parkedTotal[t0] += a0;
        _parkedTotal[t1] += a1;
        emit Parked(tokenId, g.owner, a0, a1);
    }

    /// @dev Closes and pays the owner, in the exit token when the position has one.
    function _closeOut(uint256 tokenId, Guarded memory g) internal {
        address safe = _exitToken[tokenId];
        delete _guarded[tokenId];
        (,, address t0, address t1,,,,,,,,) = npm.positions(tokenId);
        _forget(tokenId);
        (uint256 a0, uint256 a1) = _cashOut(tokenId, g, t0, t1, safe);
        if (a0 > 0 && !IERC20(t0).transfer(g.owner, a0)) revert TransferFailed();
        if (a1 > 0 && !IERC20(t1).transfer(g.owner, a1)) revert TransferFailed();
    }

    /// @dev Empties the position into the guard (AERO to the owner) and, when `safe` is one of its tokens,
    ///      swaps the other one into it in the same pool (see PositionGuard.swapOut). A swap that fails is
    ///      skipped, so a close never waits on it. Returns what this position now has on the guard.
    function _cashOut(uint256 tokenId, Guarded memory g, address t0, address t1, address safe)
        internal
        returns (uint256 a0, uint256 a1)
    {
        a0 = IERC20(t0).balanceOf(address(this));
        a1 = IERC20(t1).balanceOf(address(this));
        _empty(tokenId, g, g.owner, address(this));
        if (safe == t0 || safe == t1) {
            uint256 x = safe == t1 ? IERC20(t0).balanceOf(address(this)) - a0 : IERC20(t1).balanceOf(address(this)) - a1;
            if (x > 0) {
                try ISwapOut(address(this)).swapOut(g.pool, safe == t1, x) {}
                catch {
                    emit ExitSwapFailed(tokenId);
                }
            }
        }
        // credit what actually arrived, not what the position manager reports (Codex 26.11)
        a0 = IERC20(t0).balanceOf(address(this)) - a0;
        a1 = IERC20(t1).balanceOf(address(this)) - a1;
    }

    /// @dev Unstakes (AERO to `aeroTo`), removes all liquidity and collects the tokens and fees to `to`.
    ///      The empty NFT always goes to the owner. Returns what the collect paid out.
    function _empty(uint256 tokenId, Guarded memory g, address aeroTo, address to)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 aeroPaid = _unstake(tokenId, g, aeroTo);
        (,,,,,,, uint128 liquidity,,,,) = npm.positions(tokenId);
        if (liquidity > 0) {
            npm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: to, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        npm.transferFrom(address(this), g.owner, tokenId);
        emit Closed(tokenId, g.owner, msg.sender, amount0, amount1, aeroPaid);
    }

    /// @dev Drops every setting of a position or parked plan and takes it off the lists.
    function _forget(uint256 id) internal {
        delete alternates[id];
        delete _netExitBps[id];
        delete _rangeWatch[id];
        delete _pricePool[id];
        delete _moveVote[id];
        delete moveVoteAt[id];
        delete _reenterOn[id];
        delete _exitToken[id];
        _unlist(id);
    }

    /// @dev Removes a parked plan and its coins from the books (the coins are still on the guard).
    function _unpark(uint256 id, Park memory k) internal {
        delete _parked[id];
        _parkedTotal[k.token0] -= k.bal0;
        _parkedTotal[k.token1] -= k.bal1;
    }

    /// @dev Swaps part of the bigger side so both match, then opens ± `half` ticks around the price in
    ///      `pool` with what the guard holds above `b0`/`b1`, records and guards it for `owner`.
    function _enter(
        address owner,
        address pool,
        int24 half,
        address t0,
        address t1,
        uint256 b0,
        uint256 b1,
        uint256 min0,
        uint256 min1,
        bool stake,
        uint16 maxLoss,
        uint32 grace
    ) internal returns (uint256 tokenId) {
        if (_pushed(pool)) revert Pushed();
        _rebalance(pool, t0, t1, b0, b1);
        uint256 a0 = IERC20(t0).balanceOf(address(this)) - b0;
        uint256 a1 = IERC20(t1).balanceOf(address(this)) - b1;
        IERC20(t0).approve(address(npm), a0);
        IERC20(t1).approve(address(npm), a1);
        int24 steps = half / ICLPool(pool).tickSpacing();
        tokenId = _mintAndRecord(
            _rangeParams(pool, uint16(uint24(steps > 0 ? steps : int24(1))), t0, t1, a0, a1, min0, min1), maxLoss
        );
        // at least 80% of the value must go into the position, the rest goes back (Codex 26.11)
        uint160 sp = sugar.getSqrtRatioAtTick(_twapTick(pool));
        Guarded storage g = _guarded[tokenId];
        if ((_in1(g.entry0, sp) + g.entry1) * 5 < (_in1(a0, sp) + a1) * 4) revert TooLittleReceived();
        _guard(tokenId, owner, stake, grace);
    }

    /// @dev A range centred on the price holds equal value of both tokens, so swap half the difference
    ///      in `pool` itself. Valued at the 30-minute average; the swap may not push the price past
    ///      MAX_SPOT_DEVIATION from it and must return at least 98% of its average value.
    function _rebalance(address pool, address t0, address t1, uint256 b0, uint256 b1) internal {
        uint256 a0 = IERC20(t0).balanceOf(address(this)) - b0;
        uint256 a1 = IERC20(t1).balanceOf(address(this)) - b1;
        int24 avg = _twapTick(pool);
        uint160 sp = sugar.getSqrtRatioAtTick(avg);
        uint256 v0 = _in1(a0, sp);
        // within 1% of balanced: not worth a swap
        if ((v0 > a1 ? v0 - a1 : a1 - v0) * 100 <= v0 + a1) return;
        if (v0 > a1) {
            uint256 x = a0.mulDiv(v0 - a1, 2 * v0);
            _swap(pool, true, t0, t1, x, _in1(x, sp) * 98 / 100, sugar.getSqrtRatioAtTick(avg - MAX_SPOT_DEVIATION));
        } else {
            uint256 y = (a1 - v0) / 2;
            _swap(
                pool,
                false,
                t1,
                t0,
                y,
                y.mulDiv(Q96, sp).mulDiv(Q96, sp) * 98 / 100,
                sugar.getSqrtRatioAtTick(avg + MAX_SPOT_DEVIATION)
            );
        }
    }

    /// @dev Settings of a new position: every pool in `all` but the one it sits in becomes an alternate.
    function _settle(uint256 id, address[] memory all, address pool, address via, bool re, uint16 netExit) internal {
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != pool) alternates[id].push(all[i]);
        }
        _pricePool[id] = via;
        _reenterOn[id] = re;
        _netExitBps[id] = netExit;
    }

    /// @dev True when the pool's current price is more than MAX_SPOT_DEVIATION from its 30-minute average.
    function _pushed(address pool) internal view returns (bool) {
        (, int24 spot,,,,) = ICLPool(pool).slot0();
        int24 avg = _twapTick(pool);
        return (spot > avg ? spot - avg : avg - spot) > MAX_SPOT_DEVIATION;
    }

    /// @dev Sends `to` what the guard holds of `token` above `before`, and clears the position manager's allowance.
    function _sendNew(address token, address to, uint256 before) internal {
        IERC20(token).approve(address(npm), 0);
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > before && !IERC20(token).transfer(to, bal - before)) revert TransferFailed();
    }

    /// @dev Takes a new reading of the pool's reward counter, at most once per MIN_PAY_WINDOW, keeping
    ///      the previous one so `payRate` always has a full window to measure over.
    function _markPay(address pool) internal {
        meter.markPay(pool);
    }

    /// @dev Keeps the pool's 30-minute average tick, at most once per SNAP_GAP, overwriting the oldest.
    function _snap(address pool) internal {
        meter.snap(pool);
    }

    /// @dev The pool's average tick over the last TWAP_WINDOW, rounded towards -infinity.
    function _twapTick(address pool) internal view returns (int24) {
        return PoolMath.twapTick(pool);
    }

    /// @dev `amount0` of token0 expressed in token1 at sqrt price `sqrtP`.
    function _in1(uint256 amount0, uint160 sqrtP) internal pure returns (uint256) {
        return amount0.mulDiv(sqrtP, Q96).mulDiv(sqrtP, Q96);
    }

    /// @dev The pool's two tokens, after checking it is a real pool of the position manager's factory.
    function _poolTokens(address pool) internal view returns (address token0, address token1) {
        token0 = ICLPool(pool).token0();
        token1 = ICLPool(pool).token1();
        if (ICLFactory(npm.factory()).getPool(token0, token1, ICLPool(pool).tickSpacing()) != pool) {
            revert UnknownPool();
        }
    }

    /// @dev Mints and records what went in and the loss limit; `_guard` does the rest.
    function _mintAndRecord(INonfungiblePositionManager.MintParams memory m, uint16 maxLossBps)
        internal
        returns (uint256 tokenId)
    {
        uint256 used0;
        uint256 used1;
        nftExpected = 1;
        (tokenId,, used0, used1) = npm.mint(m);
        nftExpected = 0;
        _record(tokenId, maxLossBps, used0, used1);
    }

    function _record(uint256 tokenId, uint16 maxLossBps, uint256 entry0, uint256 entry1) internal {
        Guarded storage g = _guarded[tokenId];
        g.maxLossBps = maxLossBps;
        g.entry0 = uint128(entry0);
        g.entry1 = uint128(entry1);
    }

    /// @dev Mint parameters for a range of ± halfWidth tick spacings around the current price.
    function _rangeParams(
        address pool,
        uint16 halfWidth,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 min0,
        uint256 min1
    ) internal view returns (INonfungiblePositionManager.MintParams memory) {
        int24 spacing = ICLPool(pool).tickSpacing();
        (, int24 tick,,,,) = ICLPool(pool).slot0();
        int24 base = tick / spacing;
        if (tick < 0 && tick % spacing != 0) base -= 1; // round down for negative ticks
        int24 half = int24(uint24(halfWidth));
        return INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: spacing,
            tickLower: (base - half) * spacing,
            tickUpper: (base + 1 + half) * spacing,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: min0,
            amount1Min: min1,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
    }

    /// @dev Swaps `amountIn` of `tokenIn` for `tokenOut` in `pool` (a checked pool of the two), stopping at
    ///      `limit`; reverts if it returns less than `minOut`.
    function _swap(
        address pool,
        bool zeroForOne,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint160 limit
    ) internal {
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        swapPool = pool;
        ICLPool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(tokenIn));
        swapPool = address(0);
        if (IERC20(tokenOut).balanceOf(address(this)) - before < minOut) revert TooLittleReceived();
    }

    /// @dev Records the owner (what went in is recorded before), stakes if asked, lists the position for the daily
    ///      review, and tells the Reactive contract what to watch.
    function _guard(uint256 tokenId, address owner, bool stake, uint32 graceSeconds) internal {
        address pool = _poolOf(tokenId);
        address gauge;
        if (stake) {
            gauge = ICLPool(pool).gauge();
            npm.approve(gauge, tokenId);
            ICLGauge(gauge).deposit(tokenId);
        }
        Guarded storage g = _guarded[tokenId];
        g.owner = owner;
        g.gauge = gauge;
        g.pool = pool;
        _list(tokenId);
        _markPay(pool);
        // a pool too new to have 30 minutes of prices must not stop the deposit
        try meter.snap(pool) {} catch {}
        _rangeWatch[tokenId].grace = graceSeconds;
        emit Deposited(tokenId, owner, gauge);
    }

    /// @dev The pool a position sits in.
    function _poolOf(uint256 tokenId) internal view returns (address) {
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = npm.positions(tokenId);
        return ICLFactory(npm.factory()).getPool(token0, token1, tickSpacing);
    }

    function _list(uint256 tokenId) internal {
        if (_reviewList.length >= MAX_LISTED) revert Full();
        _reviewList.push(tokenId);
        reviewSlot[tokenId] = _reviewList.length;
    }

    function _unlist(uint256 tokenId) internal {
        uint256 slot = reviewSlot[tokenId];
        if (slot == 0) return;
        uint256 last = _reviewList[_reviewList.length - 1];
        _reviewList[slot - 1] = last;
        reviewSlot[last] = slot;
        _reviewList.pop();
        delete reviewSlot[tokenId];
    }

    /// @dev Takes `amount` of `token` from the caller.
    function _pull(address token, uint256 amount) internal {
        if (amount > 0 && !IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// @dev Claims the position's AERO to `to` and takes the NFT out of the gauge.
    ///      AERO is measured by the balance of `to` so it is right whether the gauge pays on
    ///      claim, on withdraw, or both.
    function _unstake(uint256 tokenId, Guarded memory g, address to) internal returns (uint256 aeroPaid) {
        if (g.gauge == address(0)) return 0;
        uint256 toBefore = aero.balanceOf(to);
        uint256 selfBefore = aero.balanceOf(address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        ICLGauge(g.gauge).claimEmissions(address(this), to, ids);
        nftExpected = 1;
        ICLGauge(g.gauge).withdraw(tokenId);
        nftExpected = 0;
        // Anything the gauge paid to the guard itself on withdraw belongs to this position's owner.
        if (to != address(this)) {
            uint256 stray = aero.balanceOf(address(this)) - selfBefore;
            if (stray > 0) aero.transfer(to, stray);
        }
        aeroPaid = aero.balanceOf(to) - toBefore;
    }

    /// @dev See `standing` (GuardExt).
    function _standing(uint256 tokenId)
        internal
        view
        returns (uint256 holdValue, uint256 positionValue, uint256 aeroValue)
    {
        Guarded storage g = _guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        return meter.standing(tokenId, g.pool, g.entry0, g.entry1, g.aeroPaid, _pricePool[tokenId]);
    }

    /// @dev See `netPerDay` (GuardExt).
    function _netPerDay(uint256 tokenId) internal view returns (int256 net, bool measured) {
        Guarded storage g = _guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (g.gauge == address(0)) return (0, false);
        (,,,, int24 spacing, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        return meter.netPerDay(g.pool, (upper - lower) / 2, spacing, _pricePool[tokenId]);
    }
}
