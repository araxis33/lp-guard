// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {INonfungiblePositionManager, ICLFactory, ICLPool, ICLGauge, IERC20} from "./interfaces/IAero.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// @title PositionGuard
/// @notice Holds a user's Aero (Slipstream) liquidity position, keeps it staked so it earns AERO,
///         and can close it and send everything back to the user when told to.
///
///         Who can do what:
///         - the position's owner: open one in a single step (`open`) or hand in an existing one
///           (`deposit`), take it back untouched, or close it at any time;
///         - the Reactive contract (through the callback proxy): only close it. Everything from a
///           close goes to the owner, so the worst it can do is close a position early. It can
///           never take funds. Nobody else can do anything.
contract PositionGuard is AbstractCallback {
    INonfungiblePositionManager public immutable npm;
    IERC20 public immutable aero;

    struct Guarded {
        address owner;
        address gauge; // zero when the position is held unstaked
    }

    mapping(uint256 tokenId => Guarded) public guarded;

    event Deposited(uint256 indexed tokenId, address indexed owner, address gauge);
    event Withdrawn(uint256 indexed tokenId, address indexed owner);
    event Closed(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed by,
        uint256 amount0,
        uint256 amount1,
        uint256 aeroPaid
    );
    /// @dev Read by the Reactive contract: start watching this position.
    event Watch(uint256 indexed tokenId, address indexed pool, int24 tickLower, int24 tickUpper, uint32 graceSeconds);
    /// @dev Read by the Reactive contract: stop watching.
    event Unwatch(uint256 indexed tokenId);

    error NotOwner();
    error NotGuarded();
    error UnknownPool();
    error BadWidth();
    error BadSplit();
    error BadSwapPool();
    error TooLittleReceived();
    error NotSwapPool();

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
    }

    /// @param callbackProxy_ Reactive's callback proxy on this chain.
    /// @param reactive_ The Reactive contract allowed to ask for a close.
    constructor(address npm_, address aero_, address callbackProxy_, address reactive_)
        AbstractCallback(IPayable(payable(callbackProxy_)), reactive_)
    {
        npm = INonfungiblePositionManager(npm_);
        aero = IERC20(aero_);
    }

    // ---- owner ----

    /// @notice Hand a position to the guard. The caller must own it and have approved the guard.
    /// @param stake true to stake it in the pool's gauge (earns AERO), false to hold it unstaked (earns fees).
    /// @param graceSeconds how long the price must stay outside the position's range before it is
    ///        closed automatically. Zero turns the automatic close off.
    /// @dev Any ETH sent along stays in the guard and pays for the Reactive callback.
    function deposit(uint256 tokenId, bool stake, uint32 graceSeconds) external payable {
        npm.transferFrom(msg.sender, address(this), tokenId);
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
        _unstake(tokenId, g);
        npm.transferFrom(address(this), g.owner, tokenId);
        emit Withdrawn(tokenId, g.owner);
        emit Unwatch(tokenId);
    }

    // ---- owner, or the Reactive contract ----

    /// @notice Close the position: unstake, remove all liquidity, and send both tokens, the fees
    ///         and the AERO to the owner. The empty NFT goes back to the owner as well.
    function close(uint256 tokenId) external {
        Guarded memory g = guarded[tokenId];
        if (g.owner == address(0)) revert NotGuarded();
        if (msg.sender != g.owner) revert NotOwner();
        _close(tokenId, g);
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
        _close(tokenId, g);
    }

    function _close(uint256 tokenId, Guarded memory g) internal {
        delete guarded[tokenId];

        uint256 aeroPaid = _unstake(tokenId, g);

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
                tokenId: tokenId, recipient: g.owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
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

    /// @notice Called by a pool during `_swap` to be paid. Only the pool the guard is swapping in
    ///         right now gets anything, and only the amount it is owed.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != swapPool || msg.sender == address(0)) revert NotSwapPool();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (!IERC20(tokenIn).transfer(msg.sender, owed)) revert TransferFailed();
    }

    // ---- internals ----

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
        int24 spacing = ICLPool(p.pool).tickSpacing();
        (, int24 tick,,,,) = ICLPool(p.pool).slot0();
        int24 base = tick / spacing;
        if (tick < 0 && tick % spacing != 0) base -= 1; // round down for negative ticks
        int24 half = int24(uint24(p.halfWidth));

        (tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
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
            })
        );
        _guard(tokenId, msg.sender, p.stake, p.graceSeconds);
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

    /// @dev Records the owner, stakes if asked, and tells the Reactive contract what to watch.
    function _guard(uint256 tokenId, address owner, bool stake, uint32 graceSeconds) internal {
        (,, address token0, address token1, int24 tickSpacing, int24 tickLower, int24 tickUpper,,,,,) =
            npm.positions(tokenId);
        address pool = ICLFactory(npm.factory()).getPool(token0, token1, tickSpacing);
        address gauge;
        if (stake) {
            gauge = ICLPool(pool).gauge();
            npm.approve(gauge, tokenId);
            ICLGauge(gauge).deposit(tokenId);
        }
        guarded[tokenId] = Guarded(owner, gauge);
        emit Deposited(tokenId, owner, gauge);
        if (graceSeconds > 0) emit Watch(tokenId, pool, tickLower, tickUpper, graceSeconds);
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

    /// @dev Claims the position's AERO to its owner and takes the NFT out of the gauge.
    ///      AERO is measured by the owner's balance so it is right whether the gauge pays on
    ///      claim, on withdraw, or both.
    function _unstake(uint256 tokenId, Guarded memory g) internal returns (uint256 aeroPaid) {
        if (g.gauge == address(0)) return 0;
        uint256 ownerBefore = aero.balanceOf(g.owner);
        uint256 selfBefore = aero.balanceOf(address(this));
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        ICLGauge(g.gauge).claimEmissions(address(this), g.owner, ids);
        ICLGauge(g.gauge).withdraw(tokenId);
        // Anything the gauge paid to the guard itself on withdraw belongs to this position's owner.
        uint256 stray = aero.balanceOf(address(this)) - selfBefore;
        if (stray > 0) aero.transfer(g.owner, stray);
        aeroPaid = aero.balanceOf(g.owner) - ownerBefore;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
