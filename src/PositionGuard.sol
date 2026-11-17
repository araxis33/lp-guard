// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {INonfungiblePositionManager, ICLFactory, ICLPool, ICLGauge, ILeafVoter, IERC20, ISugarHelper} from "./interfaces/IAero.sol";
import {MulDiv} from "./lib/MulDiv.sol";
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

    /// @notice Length of the price average used by a review.
    uint32 public constant TWAP_WINDOW = 30 minutes;
    /// @notice Most positions one review call goes through, so it fits in one callback.
    uint256 public constant MAX_REVIEW = 2;
    /// @notice Gas each position may use in the daily review, so one costly position (for example
    ///         one holding a token that burns gas on transfer) cannot starve the others. A close by
    ///         the net rule measures pay, swings and the AERO price first: ~1.1M on Base (17.11),
    ///         so 1.3M each, two per run, inside the Reactive contract's REVIEW_GAS of 3.5M.
    uint256 public constant GAS_PER_REVIEW = 1_300_000;
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
    uint256[] internal reviewList;
    uint256 internal reviewCursor; // where the next daily run starts
    mapping(uint256 tokenId => uint256) internal reviewSlot; // index + 1; 0 = not listed

    /// @notice Most other pools an owner may name for a position to move into.
    uint256 public constant MAX_ALTERNATES = 3;
    /// @notice Shortest stretch of time a pool's pay is measured over.
    uint64 public constant MIN_PAY_WINDOW = 12 hours;

    /// @dev Two readings of a pool's reward counter (AERO paid per unit of staked liquidity, X128),
    ///      so its pay can be measured over a real stretch of time even right after a new reading.
    struct PayMark {
        uint256 growth; // last reading
        uint64 readAt;
        uint256 prevGrowth; // the reading before it
        uint64 prevReadAt;
    }

    mapping(address pool => PayMark) public payMark;

    /// @notice How many price snapshots the guard keeps per pool, and the shortest gap between two.
    ///         Pools only remember about an hour of prices, so the guard keeps its own day of them.
    uint256 public constant SNAP_SLOTS = 24;
    uint64 public constant SNAP_GAP = 1 hours;
    /// @dev (ln 1.0001)^2 scaled by 1e18: one tick of price movement as a squared log return.
    uint256 internal constant TICK_VAR_1E18 = 9_999_000_092;

    struct Snap {
        uint64 at;
        int24 tick; // the pool's 30-minute average tick at `at`
    }

    struct SnapLog {
        uint8 next; // slot the next snapshot goes into
        uint8 count; // filled slots, up to SNAP_SLOTS
        Snap[24] snaps;
    }

    mapping(address pool => SnapLog) internal snapLog;
    /// @dev Other pools of the same two tokens the owner allows this position to move into.
    mapping(uint256 tokenId => address[]) internal alternates;
    /// @notice For a pool without AERO in it: the pool the owner named to price AERO (AERO paired
    ///         with one of the position's two tokens). Zero when not set.
    mapping(uint256 tokenId => address) public pricePool;
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
    /// @dev Read by the Reactive contract: start watching this position.
    event Watch(uint256 indexed tokenId, address indexed pool, int24 tickLower, int24 tickUpper, uint32 graceSeconds);
    /// @dev Read by the Reactive contract: stop watching.
    event Unwatch(uint256 indexed tokenId);
    event AlternatesSet(uint256 indexed tokenId, address[] pools);
    /// @notice A new reading of a pool's reward counter was taken.
    event PayMarked(address indexed pool, uint256 growth);
    /// @notice A new price snapshot of a pool was kept.
    event Snapped(address indexed pool, int24 averageTick);

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
        _unlist(tokenId);
        _unstake(tokenId, g, g.owner);
        npm.transferFrom(address(this), g.owner, tokenId);
        emit Withdrawn(tokenId, g.owner);
        emit Unwatch(tokenId);
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
        if (via != address(0)) aeroPrice(g.pool, via); // reverts unless it prices AERO for this pool
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

    /// @notice Same close, asked for by the Reactive contract. `sender_` is filled in by the
    ///         callback proxy with the Reactive contract's address.
    function closeByReactive(address sender_, uint256 tokenId)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        Guarded memory g = guarded[tokenId];
        if (g.owner == address(0)) return; // already closed or withdrawn: nothing to do
        _close(tokenId, g, g.owner);
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

    /// @dev Unstakes, removes all liquidity and sends the tokens, fees and AERO to `to` (the owner,
    ///      or the guard itself when `closeTo` swaps them first). The empty NFT always goes to the owner.
    function _close(uint256 tokenId, Guarded memory g, address to) internal {
        delete guarded[tokenId];
        delete alternates[tokenId];
        delete netExitBps[tokenId];
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
        emit Unwatch(tokenId);
    }

    // ---- views ----

    /// @notice The gauge of the pool this position sits in.
    function gaugeOf(uint256 tokenId) public view returns (address) {
        (,, address token0, address token1, int24 tickSpacing,,,,,,,) = npm.positions(tokenId);
        address pool = ICLFactory(npm.factory()).getPool(token0, token1, tickSpacing);
        return ICLPool(pool).gauge();
    }

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
            aeroValue = g.aeroPaid.mulDiv(aeroPrice(g.pool, via), 1e18);
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

    /// @notice How much AERO a pool has been paying, per second, to a staked position worth 1e18
    ///         of the pool's token1 with a range of ± `halfWidth` ticks around the price. Measured
    ///         from the pool's reward counter over at least MIN_PAY_WINDOW; zero until then.
    ///         Comparable between pools of the same two tokens.
    /// @dev The counter only grows while staked liquidity is in range, so this is what an in-range
    ///      position would have earned. Valued at the pool's 30-minute average price.
    function payRate(address pool, int24 halfWidth) public view returns (uint256) {
        PayMark memory m = payMark[pool];
        (uint256 base, uint64 since) = block.timestamp - m.readAt >= MIN_PAY_WINDOW ? (m.growth, m.readAt) : (m.prevGrowth, m.prevReadAt);
        if (since == 0) return 0;
        // A mark includes the AERO accrued but not yet settled at that moment; if the voter can't be
        // read now, the counter alone can sit below it until the pool settles. Read that as no pay
        // measured rather than as a wrap (Codex 16.11). Only views use this; closing goes by `standing`.
        uint256 current = _rewardGrowth(pool);
        uint256 grown = current > base ? current - base : 0;
        uint256 perValue = grown.mulDiv(1e18, _valuePerLiquidity(pool, halfWidth)).mulDiv(Q96, 2 ** 128);
        return perValue / (block.timestamp - since);
    }

    /// @notice Keep a price snapshot of a pool (its 30-minute average), at most once per SNAP_GAP.
    ///         Anyone may call it: the snapshot is an average the caller cannot set, and more
    ///         snapshots only make `lossRate` measure over more points. Reviews call it too.
    function snap(address pool) public {
        _poolTokens(pool); // only real pools of the factory
        _snap(pool);
    }

    /// @notice How much a staked position is expected to lose to price swings, per second, as a
    ///         share of its value scaled by 1e18, for a range of ± `halfWidth` ticks around the price.
    ///         This is the loss of providing liquidity against simply holding (loss-versus-rebalancing:
    ///         variance / 4 x sqrt(price) x liquidity), with the variance measured from the guard's own
    ///         snapshots. Zero until there are at least three snapshots.
    /// @dev Same scale as `payRate` per 1e18 of value, so once AERO is priced in token1 the two can
    ///      be compared directly: a pool is worth sitting in while it pays more than this.
    function lossRate(address pool, int24 halfWidth) public view returns (uint256) {
        uint256 variance = priceVariance(pool);
        if (variance == 0) return 0;
        uint256 sqrtP = sugar.getSqrtRatioAtTick(_twapTick(pool));
        return (variance / 4).mulDiv(sqrtP, _valuePerLiquidity(pool, halfWidth));
    }

    /// @notice What 1e18 of AERO is worth in `pool`'s token1 (raw units), at 30-minute average prices.
    ///         Read from the pool itself when AERO is one of its tokens, otherwise through `via`: a
    ///         pool of AERO and one of `pool`'s two tokens. Zero when there is no way to price it.
    function aeroPrice(address pool, address via) public view returns (uint256) {
        (address t0, address t1) = _poolTokens(pool);
        if (t1 == address(aero)) return 1e18;
        if (t0 == address(aero)) return _in1(1e18, _twapSqrt(pool));
        if (via == address(0)) return 0;
        (address v0, address v1) = _poolTokens(via);
        uint160 sv = _twapSqrt(via);
        address shared;
        uint256 inShared; // 1e18 AERO in the shared token
        if (v0 == address(aero)) {
            (shared, inShared) = (v1, _in1(1e18, sv));
        } else if (v1 == address(aero)) {
            (shared, inShared) = (v0, uint256(1e18).mulDiv(Q96, sv).mulDiv(Q96, sv));
        } else {
            revert BadPricePool();
        }
        if (shared == t1) return inShared;
        if (shared == t0) return _in1(inShared, _twapSqrt(pool));
        revert BadPricePool();
    }

    /// @notice What a staked position in `pool` gains per second, as a share of its value scaled by
    ///         1e18: the AERO it is paid (priced in token1) minus what it is expected to lose to price
    ///         swings. Positive: sitting in the pool beats holding the two tokens. `via` prices AERO
    ///         when the pool has none (see `aeroPrice`).
    function netRate(address pool, int24 halfWidth, address via) public view returns (int256) {
        uint256 pay = payRate(pool, halfWidth).mulDiv(aeroPrice(pool, via), 1e18);
        return int256(pay) - int256(lossRate(pool, halfWidth));
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
        (,,,, int24 spacing, int24 lower, int24 upper,,,,,) = npm.positions(tokenId);
        int24 half = (upper - lower) / 2;
        address via = pricePool[tokenId];
        PayMark memory m = payMark[g.pool];
        uint64 since = block.timestamp - m.readAt >= MIN_PAY_WINDOW ? m.readAt : m.prevReadAt;
        // a range one tick spacing wide has no half-width netRate can value: not measured
        if (g.gauge == address(0) || since == 0 || half < spacing || priceVariance(g.pool) == 0) return (0, false);
        // the price pool may lose its 30-minute history and revert: then this is simply not measured
        try this.aeroPrice(g.pool, via) returns (uint256 price) {
            if (price == 0) return (0, false);
        } catch {
            return (0, false);
        }
        measured = true;
        net = netRate(g.pool, half, via) * 1 days;
    }

    /// @notice Variance of the pool's log price per second, scaled by 1e18, from the snapshots kept.
    ///         Zero until there are at least three snapshots.
    function priceVariance(address pool) public view returns (uint256) {
        SnapLog storage l = snapLog[pool];
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

    /// @notice The snapshots kept for a pool, oldest first.
    function snapsOf(address pool) external view returns (Snap[] memory out) {
        SnapLog storage l = snapLog[pool];
        uint256 n = l.count;
        out = new Snap[](n);
        uint256 first = (uint256(l.next) + SNAP_SLOTS - n) % SNAP_SLOTS;
        for (uint256 i = 0; i < n; i++) {
            out[i] = l.snaps[(first + i) % SNAP_SLOTS];
        }
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
        if (behind) _close(tokenId, g, g.owner);
        else _markPays(tokenId, g.pool);
    }

    /// @dev Takes a new reading of the pool's reward counter, at most once per MIN_PAY_WINDOW, keeping
    ///      the previous one so `payRate` always has a full window to measure over.
    function _markPay(address pool) internal {
        PayMark storage m = payMark[pool];
        if (m.readAt != 0 && block.timestamp - m.readAt < MIN_PAY_WINDOW) return;
        uint256 growth = _rewardGrowth(pool);
        if (growth < m.growth) growth = m.growth; // a failed voter read never moves the mark back
        m.prevGrowth = m.growth;
        m.prevReadAt = m.readAt;
        m.growth = growth;
        m.readAt = uint64(block.timestamp);
        emit PayMarked(pool, growth);
    }

    /// @dev Reads the reward counter and keeps a price snapshot for the current pool and its alternates.
    function _markPays(uint256 tokenId, address pool) internal {
        _markPay(pool);
        _snap(pool);
        address[] storage alts = alternates[tokenId];
        for (uint256 i = 0; i < alts.length; i++) {
            _markPay(alts[i]);
            // a pool too new to have 30 minutes of prices must not stop the review of this position
            try this.snap(alts[i]) {} catch {}
        }
    }

    /// @dev Keeps the pool's 30-minute average tick, at most once per SNAP_GAP, overwriting the oldest.
    function _snap(address pool) internal {
        SnapLog storage l = snapLog[pool];
        if (l.count > 0) {
            uint256 last = (uint256(l.next) + SNAP_SLOTS - 1) % SNAP_SLOTS;
            if (block.timestamp - l.snaps[last].at < SNAP_GAP) return;
        }
        int24 tick = _twapTick(pool);
        l.snaps[l.next] = Snap({at: uint64(block.timestamp), tick: tick});
        l.next = uint8((uint256(l.next) + 1) % SNAP_SLOTS);
        if (l.count < SNAP_SLOTS) l.count++;
        emit Snapped(pool, tick);
    }

    /// @dev The pool's reward counter as it would read if updated now. The pool itself only brings it
    ///      up to date when touched, so a quiet pool would read as paying nothing and then, at its next
    ///      swap, as having paid everything at once. Mirrors CLPool._settleToBlock: the AERO accrued
    ///      since the last settlement is the gauge's unsettled reward share, read from the LeafVoter
    ///      (checked on Base 16.11.2026: ~3.9 AERO over 12 s on AERO/WETH CL200). If any of these
    ///      reads fails, the counter is taken as it stands rather than failing the review.
    function _rewardGrowth(address pool) internal view returns (uint256 growth) {
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

    /// @dev What one unit of liquidity is worth in token1, X96, for a range of ± `halfWidth` ticks
    ///      (rounded to the pool's step, at least one step) around the 30-minute average price.
    function _valuePerLiquidity(address pool, int24 halfWidth) internal view returns (uint256) {
        int24 tick = _twapTick(pool);
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

    /// @dev sqrt price at the pool's average tick over the last TWAP_WINDOW.
    ///      Both the position and holding are valued at this one price (the position at the amounts
    ///      it would hold there), so a trade that moves the spot price changes neither number.
    function _twapSqrt(address pool) internal view returns (uint160) {
        return sugar.getSqrtRatioAtTick(_twapTick(pool));
    }

    /// @dev The pool's average tick over the last TWAP_WINDOW, rounded towards -infinity.
    function _twapTick(address pool) internal view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        (int56[] memory cum,) = _observe(pool, ago);
        int56 delta = cum[1] - cum[0];
        tick = int24(delta / int56(uint56(TWAP_WINDOW)));
        if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) tick--;
    }

    function _observe(address pool, uint32[] memory ago)
        internal
        view
        returns (int56[] memory cum, uint160[] memory spl)
    {
        try ICLPool(pool).observe(ago) returns (int56[] memory c, uint160[] memory s) {
            return (c, s);
        } catch {
            revert NoPriceHistory();
        }
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
        tokenId = _mintAndRecord(_mintParams(p, token0, token1, amount0, amount1), p.maxLossBps);
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
    function _mintParams(OpenParams calldata p, address token0, address token1, uint256 amount0, uint256 amount1)
        internal
        view
        returns (INonfungiblePositionManager.MintParams memory)
    {
        int24 spacing = ICLPool(p.pool).tickSpacing();
        (, int24 tick,,,,) = ICLPool(p.pool).slot0();
        int24 base = tick / spacing;
        if (tick < 0 && tick % spacing != 0) base -= 1; // round down for negative ticks
        int24 half = int24(uint24(p.halfWidth));
        return INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: spacing,
            tickLower: (base - half) * spacing,
            tickUpper: (base + 1 + half) * spacing,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: p.amount0Min,
            amount1Min: p.amount1Min,
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
        emit Deposited(tokenId, owner, gauge);
        if (graceSeconds > 0) _emitWatch(tokenId, pool, graceSeconds);
    }

    function _emitWatch(uint256 tokenId, address pool, uint32 graceSeconds) internal {
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = npm.positions(tokenId);
        emit Watch(tokenId, pool, tickLower, tickUpper, graceSeconds);
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
