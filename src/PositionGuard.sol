// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {INonfungiblePositionManager, ICLFactory, ICLPool, ICLGauge, IERC20, ISugarHelper} from "./interfaces/IAero.sol";
import {MulDiv} from "./lib/MulDiv.sol";
import {PoolMath} from "./lib/PoolMath.sol";
import {GuardMeter} from "./GuardMeter.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// @title PositionGuard
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
contract PositionGuard is AbstractCallback {
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
    ///         and a move into a better pool ~2.5M (19.11), so 2.8M each, two per run, inside the
    ///         Reactive contract's REVIEW_GAS of 6M.
    uint256 public constant GAS_PER_REVIEW = 2_800_000;
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

    mapping(uint256 tokenId => Guarded) public guarded;
    uint256[] public reviewList;
    uint256 internal reviewCursor; // where the next daily run starts
    mapping(uint256 tokenId => uint256) internal reviewSlot; // index + 1; 0 = not listed

    /// @notice Most other pools an owner may name for a position to move into.
    uint256 public constant MAX_ALTERNATES = 3;
    /// @dev Other pools of the same two tokens the owner allows this position to move into.
    mapping(uint256 tokenId => address[]) internal alternates;
    /// @notice For a pool without AERO in it: the pool the owner named to price AERO (AERO paired
    ///         with one of the position's two tokens). Zero when not set.
    mapping(uint256 tokenId => address) public pricePool;
    /// @dev Per position: how long the price may stay out of range before the hourly check closes it
    ///      (0 = never), and since when it has been out (0 = inside at the last check).
    struct RangeWatch {
        uint32 grace;
        uint64 outSince;
    }

    mapping(uint256 tokenId => RangeWatch) public rangeWatch;
    /// @notice Most positions one hourly check goes through, so it fits in one callback.
    uint256 public constant MAX_CHECK = 2;
    /// @notice Gas each position may use in the hourly check (the fork test measures a close).
    uint256 public constant GAS_PER_CHECK = 1_300_000;
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
    mapping(uint256 tokenId => address) public moveVote;
    /// @notice The review moved a position into a pool that earns more. Coins that did not fit the
    ///         new range at the moment of the move went straight to the owner.
    event Moved(uint256 indexed fromTokenId, uint256 indexed toTokenId, address indexed pool);

    /// @notice A position's hourly check reverted or ran out of its gas; it is tried again next hour.
    event CheckFailed(uint256 indexed tokenId);
    /// @dev Gas for each alternate pool's snapshot in the hourly check.
    uint256 internal constant SNAP_GAS = 120_000;

    /// @notice Per position: the review closes it when the pool's pay minus its expected loss to
    ///         price swings falls below minus this many basis points of its value a day. 0 = off.
    mapping(uint256 tokenId => uint16) public netExitBps;
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

    /// @dev The pool the guard is swapping in right now; only it may ask to be paid.
    address internal swapPool;

    // TransferFailed() comes from AbstractPayer (via AbstractCallback).

    /// @notice What `open` needs. The range is placed around the pool's current price.
    struct OpenParams {
        address pool; // an Aero Slipstream pool; checked against the factory
        uint256 amount0; // most of token0 to put in
        uint256 amount1; // most of token1 to put in
        uint16 halfWidth; // range = current price ± halfWidth tick spacings (at least 1)
        uint256 amount0Min; // slippage guard: least token0 that must go in
        uint256 amount1Min; // slippage guard: least token1 that must go in
        bool stake; // stake in the gauge to earn AERO
        uint32 graceSeconds; // automatic close after this long out of range; 0 = off
        uint16 maxLossBps; // daily review closes when behind holding by more than this; 0 = off
    }

    /// @param callbackProxy_ Reactive's callback proxy on this chain.
    /// @param reactive_ The Reactive contract allowed to ask for a close or a review.
    /// @param sugar_ Aero's SugarHelper, used to value positions.
    constructor(address npm_, address aero_, address callbackProxy_, address reactive_, address sugar_)
        AbstractCallback(IPayable(payable(callbackProxy_)), reactive_)
    {
        npm = INonfungiblePositionManager(npm_);
        aero = IERC20(aero_);
        sugar = ISugarHelper(sugar_);
        meter = new GuardMeter(INonfungiblePositionManager(npm_).factory(), aero_, sugar_);
    }

    // ---- owner ----

    /// @notice Hand a position to the guard. The caller must own it and have approved the guard.
    ///         The review compares against what the position holds at this moment.
    /// @param stake true to stake it in the pool's gauge (earns AERO), false to hold it unstaked (earns fees).
    /// @param graceSeconds how long the price must stay outside the position's range before it is
    ///        closed automatically. Zero turns the automatic close off.
    /// @dev Any ETH sent along stays in the guard and pays for the Reactive callback.
    function deposit(uint256 tokenId, bool stake, uint32 graceSeconds) external payable {
        npm.transferFrom(msg.sender, address(this), tokenId);
        (uint160 sqrtP,,,,,) = ICLPool(_poolOf(tokenId)).slot0();
        (uint256 a0, uint256 a1) = sugar.principal(address(npm), tokenId, sqrtP);
        _record(tokenId, 0, a0, a1);
        _guard(tokenId, msg.sender, stake, graceSeconds);
    }

    /// @notice One step in: take the two tokens, open a position around the current price in
    ///         `p.pool`, stake it, and guard it for the caller. Whatever the pool did not take is
    ///         sent straight back. The caller must have approved the guard for both amounts.
    /// @dev Any ETH sent along stays in the guard and pays for the Reactive callback.
    function open(OpenParams calldata p) external payable returns (uint256 tokenId) {
        if (p.halfWidth == 0) revert BadWidth();
        (address token0, address token1) = _poolTokens(p.pool);
        _pull(token0, p.amount0);
        _pull(token1, p.amount1);
        tokenId = _mintAndGuard(p, token0, token1, p.amount0, p.amount1);
        _refund(token0);
        _refund(token1);
    }

    /// @notice One step in from a single token (for example USDC): part of it is swapped into the
    ///         pool's two tokens, then the position is opened, staked and guarded as in `open`.
    ///         Whatever is left of any of the three tokens goes straight back to the caller.
    /// @param tokenIn the token the caller pays with; may be one of the pool's own tokens.
    /// @param amountIn how much of it to take. The caller must have approved the guard.
    /// @param to0 swap of `tokenIn` into the pool's token0 (skipped when `tokenIn` is token0).
    /// @param to1 swap of `tokenIn` into the pool's token1 (skipped when `tokenIn` is token1).
    /// @param p the position to open; `p.amount0` and `p.amount1` are ignored: everything the swaps
    ///        produced (plus any `tokenIn` that is a pool token) is offered to the pool.
    /// @dev The split between the two swaps and the `minOut` floors are worked out off-chain by the
    ///      page from the pool's current price; the floors make a moved price revert, not lose money.
    function openWith(
        address tokenIn,
        uint256 amountIn,
        SwapLeg calldata to0,
        SwapLeg calldata to1,
        OpenParams calldata p
    ) external payable returns (uint256 tokenId) {
        if (p.halfWidth == 0) revert BadWidth();
        (address token0, address token1) = _poolTokens(p.pool);
        if (to0.amountIn + to1.amountIn > amountIn) revert BadSplit();
        if (!IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();

        if (tokenIn != token0) _swap(to0.pool, tokenIn, token0, to0.amountIn, to0.minOut);
        if (tokenIn != token1) _swap(to1.pool, tokenIn, token1, to1.amountIn, to1.minOut);

        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));
        IERC20(token0).approve(address(npm), amount0);
        IERC20(token1).approve(address(npm), amount1);
        tokenId = _mintAndGuard(p, token0, token1, amount0, amount1);
        _refund(token0);
        _refund(token1);
        if (tokenIn != token0 && tokenIn != token1) _refund(tokenIn);
    }

    /// @notice Take the position back as it is, with any AERO it earned.
    function withdraw(uint256 tokenId) external {
        Guarded memory g = guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        delete guarded[tokenId];
        delete alternates[tokenId];
        delete netExitBps[tokenId];
        delete rangeWatch[tokenId];
        delete pricePool[tokenId];
        delete moveVote[tokenId];
        _unlist(tokenId);
        _unstake(tokenId, g, g.owner);
        npm.transferFrom(address(this), g.owner, tokenId);
        emit Withdrawn(tokenId, g.owner);
    }

    /// @notice Set how far behind simply holding the position may fall before the daily review
    ///         closes it, in basis points (100 = 1%). Zero: the review only reports, never closes.
    function setMaxLoss(uint256 tokenId, uint16 maxLossBps) external {
        Guarded storage g = guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (maxLossBps >= 10_000) revert BadLimit();
        g.maxLossBps = maxLossBps;
        emit MaxLossSet(tokenId, maxLossBps);
    }

    /// @notice Name up to three other pools of the same two tokens (for example the same pair with a
    ///         different price step) that this position may be moved into when they pay more.
    ///         An empty list turns moving off.
    function setAlternates(uint256 tokenId, address[] calldata pools) external {
        Guarded storage g = guarded[tokenId];
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
        Guarded storage g = guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (via != address(0)) meter.aeroPrice(g.pool, via); // reverts unless it prices AERO for this pool
        pricePool[tokenId] = via;
        emit PricePoolSet(tokenId, via);
    }

    /// @notice Close at the review when sitting in the pool no longer pays: the AERO the pool pays
    ///         (priced in token1) minus what the position is expected to lose to price swings
    ///         (`netRate`) is below minus `bpsPerDay` basis points of its value a day. Owner only.
    ///         Zero turns it off. Only staked positions earn AERO, so it only acts on those, and only
    ///         once the pool's pay, price swings and AERO price have all been measured.
    function setNetExit(uint256 tokenId, uint16 bpsPerDay) external {
        Guarded storage g = guarded[tokenId];
        if (g.owner != msg.sender) revert NotOwner();
        if (bpsPerDay >= 10_000) revert BadLimit();
        netExitBps[tokenId] = bpsPerDay;
        emit NetExitSet(tokenId, bpsPerDay);
    }

    /// @notice Review one position now, without waiting for the daily run. Owner only.
    function review(uint256 tokenId) external {
        if (guarded[tokenId].owner != msg.sender) revert NotOwner();
        _review(tokenId);
    }

    // ---- owner, or the Reactive contract ----

    /// @notice Close the position: unstake, remove all liquidity, and send both tokens, the fees
    ///         and the AERO to the owner. The empty NFT goes back to the owner as well.
    function close(uint256 tokenId) external {
        Guarded memory g = guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (msg.sender != g.owner) revert NotOwner();
        _close(tokenId, g, g.owner);
    }

    /// @notice Close the position and get it all back in one token (for example USDC): both of the
    ///         pool's tokens are swapped into `tokenOut`; AERO earned is swapped too when it is one
    ///         of the pool's tokens, otherwise it is sent as AERO. Owner only.
    /// @param from0 swap of the pool's token0 into `tokenOut` (skipped when token0 is `tokenOut`);
    ///        its `amountIn` is ignored: everything the position returned is swapped.
    /// @param from1 the same for token1.
    /// @return out how much `tokenOut` the owner received.
    /// @dev The `minOut` floors are worked out off-chain by the page from the position's current
    ///      amounts; if the price moved, the whole close reverts and the position stays as it was.
    function closeTo(uint256 tokenId, address tokenOut, SwapLeg calldata from0, SwapLeg calldata from1)
        external
        returns (uint256 out)
    {
        Guarded memory g = guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (msg.sender != g.owner) revert NotOwner();
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);

        _close(tokenId, g, address(this));

        if (token0 != tokenOut) {
            _swap(from0.pool, token0, tokenOut, IERC20(token0).balanceOf(address(this)), from0.minOut);
        }
        if (token1 != tokenOut) {
            _swap(from1.pool, token1, tokenOut, IERC20(token1).balanceOf(address(this)), from1.minOut);
        }
        out = IERC20(tokenOut).balanceOf(address(this));
        _refund(tokenOut);
        _refund(token0);
        _refund(token1);
        _refund(address(aero));
    }

    /// @notice The daily review of every guarded position, asked for by the Reactive contract's
    ///         timer. A position whose pool has no price history yet is skipped, not closed.
    function reviewByReactive(address sender_) external onlyServiceProvider onlyCallbackSender(sender_) {
        uint256 len = reviewList.length;
        if (len == 0) return;
        uint256 n = len < MAX_REVIEW ? len : MAX_REVIEW;
        uint256 start = reviewCursor % len;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = reviewList[(start + i) % len];
        }
        // Next run starts where this one stops, so every position gets its turn.
        reviewCursor = start + n;
        for (uint256 i = 0; i < n; i++) {
            if (gasleft() < GAS_PER_REVIEW + 50_000) break;
            try this.reviewOne{gas: GAS_PER_REVIEW}(ids[i]) {} catch {}
        }
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
    function checkByReactive(address sender_) external onlyServiceProvider onlyCallbackSender(sender_) {
        uint256 len = reviewList.length;
        if (len == 0) return;
        uint256 n = len < MAX_CHECK ? len : MAX_CHECK;
        uint256 start = checkCursor % len;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = reviewList[(start + i) % len];
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
        Guarded memory g = guarded[tokenId];
        if (g.owner == address(0)) return;
        _snap(g.pool);
        if (_rangeStep(tokenId, g)) return; // closed
        address[] storage alts = alternates[tokenId];
        for (uint256 i = 0; i < alts.length; i++) {
            try meter.snap{gas: SNAP_GAS}(alts[i]) {} catch {}
        }
    }

    /// @dev Updates the out-of-range clock of a position and closes it when the grace period is over
    ///      and both the 30-minute average and the current price are out of range. True if closed.
    function _rangeStep(uint256 tokenId, Guarded memory g) internal returns (bool) {
        RangeWatch storage w = rangeWatch[tokenId];
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
        _close(tokenId, g, g.owner);
        return true;
    }

    /// @dev Unstakes, removes all liquidity and sends the tokens, fees and AERO to `to` (the owner,
    ///      or the guard itself when `closeTo` swaps them first). The empty NFT always goes to the owner.
    function _close(uint256 tokenId, Guarded memory g, address to) internal {
        delete guarded[tokenId];
        delete alternates[tokenId];
        delete netExitBps[tokenId];
        delete rangeWatch[tokenId];
        delete pricePool[tokenId];
        delete moveVote[tokenId];
        _unlist(tokenId);

        uint256 aeroPaid = _unstake(tokenId, g, to);

        (,,,,,,, uint128 liquidity,,,,) = npm.positions(tokenId);
        if (liquidity > 0) {
            npm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            );
        }
        (uint256 amount0, uint256 amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: to, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        npm.transferFrom(address(this), g.owner, tokenId);
        emit Closed(tokenId, g.owner, msg.sender, amount0, amount1, aeroPaid);
    }

    // ---- views ----


    /// @notice AERO the position has earned in the gauge and not yet claimed.
    function pendingAero(uint256 tokenId) external view returns (uint256) {
        Guarded memory g = guarded[tokenId];
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
        Guarded storage g = guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        uint160 sqrtP = _twapSqrt(g.pool);
        holdValue = _in1(g.entry0, sqrtP) + g.entry1;
        positionValue = _positionValue(tokenId, sqrtP);
        aeroValue = _aeroValue(g.pool, g.aeroPaid, sqrtP);
        address via = pricePool[tokenId];
        if (aeroValue == 0 && g.aeroPaid > 0 && via != address(0)) {
            // the pool has no AERO in it: price the AERO paid through the owner's price pool
            aeroValue = g.aeroPaid.mulDiv(meter.aeroPrice(g.pool, via), 1e18);
        }
    }

    /// @dev The position's tokens plus its unclaimed fees, in token1.
    function _positionValue(uint256 tokenId, uint160 sqrtP) internal view returns (uint256) {
        (uint256 p0, uint256 p1) = sugar.principal(address(npm), tokenId, sqrtP);
        (uint256 f0, uint256 f1) = sugar.fees(address(npm), tokenId);
        return _in1(p0 + f0, sqrtP) + p1 + f1;
    }

    /// @dev AERO in token1, when AERO is one of the pool's tokens; otherwise zero here and `standing`
    ///      prices it through the owner's price pool, if one is set.
    function _aeroValue(address pool, uint256 amount, uint160 sqrtP) internal view returns (uint256) {
        if (ICLPool(pool).token0() == address(aero)) return _in1(amount, sqrtP);
        if (ICLPool(pool).token1() == address(aero)) return amount;
        return 0;
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
        Guarded storage g = guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (g.gauge == address(0)) return (0, false);
        (,,,, int24 spacing, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        return meter.netPerDay(g.pool, (upper - lower) / 2, spacing, pricePool[tokenId]);
    }

    /// @notice Positions the daily review goes through.
    function reviewCount() external view returns (uint256) {
        return reviewList.length;
    }

    /// @notice Called by a pool during `_swap` to be paid. Only the pool the guard is swapping in
    ///         right now gets anything, and only the amount it is owed.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != swapPool || msg.sender == address(0)) revert NotSwapPool();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (!IERC20(tokenIn).transfer(msg.sender, owed)) revert TransferFailed();
    }

    // ---- internals ----

    /// @dev Claims the AERO earned so far to the owner, then compares the position with holding
    ///      and closes it if it is behind by more than the owner's limit.
    function _review(uint256 tokenId) internal {
        Guarded storage g = guarded[tokenId];
        if (g.owner == address(0)) return;
        if (g.gauge != address(0)) {
            uint256 before = aero.balanceOf(g.owner);
            uint256[] memory ids = new uint256[](1);
            ids[0] = tokenId;
            ICLGauge(g.gauge).claimEmissions(address(this), g.owner, ids);
            g.aeroPaid += aero.balanceOf(g.owner) - before;
        }
        (uint256 holdValue, uint256 positionValue, uint256 aeroValue) = standing(tokenId);
        bool behind =
            g.maxLossBps > 0 && (positionValue + aeroValue) * 10_000 < holdValue * (10_000 - uint256(g.maxLossBps));
        uint16 netLimit = netExitBps[tokenId];
        bool netDue;
        int256 net;
        if (!behind && netLimit > 0 && g.gauge != address(0)) {
            bool measured;
            (net, measured) = netPerDay(tokenId);
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
            _close(tokenId, g, g.owner);
        } else {
            _markPays(tokenId, g.pool);
            _maybeMove(tokenId);
        }
    }

    /// @dev Moves a staked position into the alternate pool that has earned the most net of price
    ///      swings, when it beats the current pool by MOVE_MARGIN at two reviews in a row and neither
    ///      pool's price is being pushed right now. Readings only: no forecast, nothing unmeasured.
    function _maybeMove(uint256 tokenId) internal {
        Guarded memory g = guarded[tokenId];
        address[] memory alts = alternates[tokenId];
        if (alts.length == 0 || g.gauge == address(0) || !meter.measured(g.pool)) return;
        (,,,,, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        int24 half = (upper - lower) / 2;
        address via = pricePool[tokenId];
        address target = meter.bestAlternate(alts, half, via, meter.netRate(g.pool, half, via) + int256(MOVE_MARGIN));
        if (target == address(0)) {
            delete moveVote[tokenId];
            return;
        }
        if (moveVote[tokenId] != target) {
            moveVote[tokenId] = target;
            return;
        }
        if (_pushed(g.pool) || _pushed(target)) return;
        _move(tokenId, g, target, half, alts);
    }

    /// @dev True when the pool's current price is more than MAX_SPOT_DEVIATION from its 30-minute average.
    function _pushed(address pool) internal view returns (bool) {
        (, int24 spot,,,,) = ICLPool(pool).slot0();
        int24 avg = _twapTick(pool);
        return (spot > avg ? spot - avg : avg - spot) > MAX_SPOT_DEVIATION;
    }

    /// @dev Closes the position into the guard and opens one of the same width around the price in
    ///      `target`, staked and guarded with the same settings. The old pool becomes an alternate.
    ///      AERO earned and whatever the new range does not take go straight to the owner.
    function _move(uint256 tokenId, Guarded memory g, address target, int24 half, address[] memory alts) internal {
        uint16 maxLoss = g.maxLossBps;
        uint16 netExit = netExitBps[tokenId];
        uint32 grace = rangeWatch[tokenId].grace;
        address via = pricePool[tokenId];
        _close(tokenId, g, address(this));

        (address t0, address t1) = _poolTokens(target);
        uint256 a0 = IERC20(t0).balanceOf(address(this));
        uint256 a1 = IERC20(t1).balanceOf(address(this));
        IERC20(t0).approve(address(npm), a0);
        IERC20(t1).approve(address(npm), a1);
        int24 steps = half / ICLPool(target).tickSpacing();
        uint256 newId = _mintAndRecord(
            _rangeParams(target, uint16(uint24(steps > 0 ? steps : int24(1))), t0, t1, a0, a1, 0, 0), maxLoss
        );
        _guard(newId, g.owner, true, grace);
        netExitBps[newId] = netExit;
        pricePool[newId] = via;
        for (uint256 i = 0; i < alts.length; i++) {
            if (alts[i] == target) alts[i] = g.pool;
        }
        alternates[newId] = alts;
        _sendAll(t0, g.owner);
        _sendAll(t1, g.owner);
        _sendAll(address(aero), g.owner);
        emit Moved(tokenId, newId, target);
    }

    /// @dev Sends the guard's whole balance of `token` to `to` and clears its allowance to the position manager.
    function _sendAll(address token, address to) internal {
        IERC20(token).approve(address(npm), 0);
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0 && !IERC20(token).transfer(to, bal)) revert TransferFailed();
    }

    /// @dev Takes a new reading of the pool's reward counter, at most once per MIN_PAY_WINDOW, keeping
    ///      the previous one so `payRate` always has a full window to measure over.
    function _markPay(address pool) internal {
        meter.markPay(pool);
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

    /// @dev Keeps the pool's 30-minute average tick, at most once per SNAP_GAP, overwriting the oldest.
    function _snap(address pool) internal {
        meter.snap(pool);
    }



    /// @dev sqrt price at the pool's average tick over the last TWAP_WINDOW.
    ///      Both the position and holding are valued at this one price (the position at the amounts
    ///      it would hold there), so a trade that moves the spot price changes neither number.
    function _twapSqrt(address pool) internal view returns (uint160) {
        return sugar.getSqrtRatioAtTick(_twapTick(pool));
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

    /// @dev Opens the position around the current price and guards it for the caller.
    ///      The position manager must already be approved for `amount0` and `amount1`.
    function _mintAndGuard(OpenParams calldata p, address token0, address token1, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        if (p.maxLossBps >= 10_000) revert BadLimit();
        tokenId = _mintAndRecord(
            _rangeParams(p.pool, p.halfWidth, token0, token1, amount0, amount1, p.amount0Min, p.amount1Min),
            p.maxLossBps
        );
        _guard(tokenId, msg.sender, p.stake, p.graceSeconds);
    }

    /// @dev Mints and records what went in and the loss limit; `_guard` does the rest.
    function _mintAndRecord(INonfungiblePositionManager.MintParams memory m, uint16 maxLossBps)
        internal
        returns (uint256 tokenId)
    {
        uint256 used0;
        uint256 used1;
        (tokenId,, used0, used1) = npm.mint(m);
        _record(tokenId, maxLossBps, used0, used1);
    }

    function _record(uint256 tokenId, uint16 maxLossBps, uint256 entry0, uint256 entry1) internal {
        Guarded storage g = guarded[tokenId];
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

    /// @dev Swaps exactly `amountIn` of `tokenIn` (or less, if the pool runs out) for `tokenOut`
    ///      in `pool`, which must be a real pool of exactly these two tokens.
    function _swap(address pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal {
        if (amountIn == 0) return;
        (address t0, address t1) = _poolTokens(pool);
        bool zeroForOne = tokenIn == t0;
        if (zeroForOne ? t1 != tokenOut : (t1 != tokenIn || t0 != tokenOut)) revert BadSwapPool();

        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        swapPool = pool;
        ICLPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                abi.encode(tokenIn)
            );
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
        Guarded storage g = guarded[tokenId];
        g.owner = owner;
        g.gauge = gauge;
        g.pool = pool;
        _list(tokenId);
        _markPay(pool);
        // a pool too new to have 30 minutes of prices must not stop the deposit
        try meter.snap(pool) {} catch {}
        rangeWatch[tokenId].grace = graceSeconds;
        emit Deposited(tokenId, owner, gauge);
    }

    /// @dev The pool a position sits in.
    function _poolOf(uint256 tokenId) internal view returns (address) {
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = npm.positions(tokenId);
        return ICLFactory(npm.factory()).getPool(token0, token1, tickSpacing);
    }

    function _list(uint256 tokenId) internal {
        reviewList.push(tokenId);
        reviewSlot[tokenId] = reviewList.length;
    }

    function _unlist(uint256 tokenId) internal {
        uint256 slot = reviewSlot[tokenId];
        if (slot == 0) return;
        uint256 last = reviewList[reviewList.length - 1];
        reviewList[slot - 1] = last;
        reviewSlot[last] = slot;
        reviewList.pop();
        delete reviewSlot[tokenId];
    }

    /// @dev Takes `amount` of `token` from the caller and lets the position manager spend exactly that.
    function _pull(address token, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (!IERC20(token).approve(address(npm), amount)) revert TransferFailed();
    }

    /// @dev Sends back what the mint did not use and clears the leftover allowance.
    ///      The guard never holds tokens between calls, so its whole balance is the leftover.
    function _refund(address token) internal {
        IERC20(token).approve(address(npm), 0);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left > 0 && !IERC20(token).transfer(msg.sender, left)) revert TransferFailed();
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
        ICLGauge(g.gauge).withdraw(tokenId);
        // Anything the gauge paid to the guard itself on withdraw belongs to this position's owner.
        if (to != address(this)) {
            uint256 stray = aero.balanceOf(address(this)) - selfBefore;
            if (stray > 0) aero.transfer(to, stray);
        }
        aeroPaid = aero.balanceOf(to) - toBefore;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
