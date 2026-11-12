// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// Testnet stand-ins used only to prove the loop "pool event -> Reactive -> callback" on
/// Base Sepolia, where Aero is not deployed. GuardReactive itself is the real contract.

/// A pool that emits the same Swap event as a Slipstream / Uniswap V3 pool, at a tick we choose.
contract ProbePool {
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    function swapTo(int24 tick) external {
        emit Swap(msg.sender, msg.sender, 1, -1, 1, 1, tick);
    }
}

/// Emits the guard's Watch / Unwatch events and records the close callback.
contract ProbeGuard is AbstractCallback {
    event Watch(uint256 indexed tokenId, address indexed pool, int24 tickLower, int24 tickUpper, uint32 graceSeconds);
    event Unwatch(uint256 indexed tokenId);
    event ClosedByReactive(uint256 indexed tokenId, uint256 at);

    mapping(uint256 => uint256) public closedAt;

    constructor(address callbackProxy_, address reactive_) payable
        AbstractCallback(IPayable(payable(callbackProxy_)), reactive_)
    {}

    function watch(uint256 tokenId, address pool, int24 lo, int24 hi, uint32 grace) external {
        emit Watch(tokenId, pool, lo, hi, grace);
    }

    function closeByReactive(address sender_, uint256 tokenId) external onlyServiceProvider onlyCallbackSender(sender_) {
        closedAt[tokenId] = block.timestamp;
        emit ClosedByReactive(tokenId, block.timestamp);
        emit Unwatch(tokenId);
    }
}
