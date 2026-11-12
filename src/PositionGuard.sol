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
///         - the position's owner: put it in, take it back untouched, or close it at any time;
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
        (,, address token0, address token1, int24 tickSpacing, int24 tickLower, int24 tickUpper,,,,,) =
            npm.positions(tokenId);
        address pool = ICLFactory(npm.factory()).getPool(token0, token1, tickSpacing);
        address gauge;
        if (stake) {
            gauge = ICLPool(pool).gauge();
            npm.approve(gauge, tokenId);
            ICLGauge(gauge).deposit(tokenId);
        }
        guarded[tokenId] = Guarded(msg.sender, gauge);
        emit Deposited(tokenId, msg.sender, gauge);
        if (graceSeconds > 0) emit Watch(tokenId, pool, tickLower, tickUpper, graceSeconds);
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

    // ---- internals ----

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
