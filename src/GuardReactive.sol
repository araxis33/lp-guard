// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title GuardReactive
/// @notice Lives on Reactive Network. Listens to the PositionGuard on Base and to the swaps of the
///         pools its positions sit in. When a pool's price has stayed outside a position's range
///         for that position's grace period, it asks the guard to close the position.
///
///         It never holds user funds and can only ask for one thing: closeByReactive(tokenId).
contract GuardReactive is AbstractReactive {
    // keccak256("Watch(uint256,address,int24,int24,uint32)")
    uint256 public constant WATCH_TOPIC = uint256(keccak256("Watch(uint256,address,int24,int24,uint32)"));
    // keccak256("Unwatch(uint256)")
    uint256 public constant UNWATCH_TOPIC = uint256(keccak256("Unwatch(uint256)"));
    // Uniswap V3 / Slipstream pool swap
    uint256 public constant SWAP_TOPIC =
        uint256(keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)"));

    uint64 public constant CALLBACK_GAS = 1_000_000;
    /// @notice Gas for the daily review callback: it may claim, value and close up to four positions
    ///         (measured on a Base fork: two positions, one closed, ~1.13M).
    uint64 public constant REVIEW_GAS = 3_000_000;
    /// @notice Reactive Network's system contract that emits the Cron timer events.
    address public constant CRON = 0x0000000000000000000000000000000000fffFfF;

    /// @notice topic0 of the Cron event this contract wakes up on; 0 while the review is off.
    uint256 public cronTopic;
    /// @notice How often the review runs, in seconds.
    uint32 public reviewEvery;
    /// @notice When the last review was asked for.
    uint64 public lastReview;
    /// @dev Upper bound on positions checked per swap, so one react() stays well under the gas cap.
    uint256 public constant MAX_PER_POOL = 40;

    uint256 public immutable originChainId;
    address public immutable deployer;
    address public guard;

    struct Position {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint32 grace;
        uint64 outSince; // 0 while the price is inside the range
        bool active;
    }

    mapping(uint256 tokenId => Position) public positions;
    mapping(address pool => uint256[]) internal watched; // active tokenIds per pool
    mapping(address pool => bool) public subscribed;

    event Watching(uint256 indexed tokenId, address indexed pool);
    event Stopped(uint256 indexed tokenId);
    event WentOut(uint256 indexed tokenId, int24 tick);
    event CameBack(uint256 indexed tokenId, int24 tick);
    event CloseRequested(uint256 indexed tokenId, int24 tick, uint64 outFor);
    event ReviewRequested(uint64 at);

    error NotDeployer();
    error GuardAlreadySet();
    error ReviewAlreadySet();
    error GuardNotSet();

    constructor(uint256 originChainId_) payable {
        originChainId = originChainId_;
        deployer = msg.sender;
    }

    /// @notice One-time wiring: the guard is deployed after this contract, because the guard needs
    ///         this contract's address in its constructor.
    function setGuard(address guard_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (guard != address(0)) revert GuardAlreadySet();
        guard = guard_;
        SYSTEM.subscribe(originChainId, guard_, WATCH_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId, guard_, UNWATCH_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice One-time switch-on of the daily review: wake up on a Reactive Cron event and, at most
    ///         once per `every_` seconds, ask the guard to review all positions.
    /// @param cronTopic_ topic0 of the Cron event to wake up on (a slower one costs less: every
    ///        tick is paid for).
    function setReview(uint256 cronTopic_, uint32 every_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (guard == address(0)) revert GuardNotSet();
        if (cronTopic != 0) revert ReviewAlreadySet();
        cronTopic = cronTopic_;
        reviewEvery = every_;
        SYSTEM.subscribe(block.chainid, CRON, cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.contractAddress == CRON) {
            if (cronTopic != 0 && log_.topic0 == cronTopic) _onTick();
            return;
        }
        if (log_.chainId != originChainId) return;
        if (log_.contractAddress == guard) {
            if (log_.topic0 == WATCH_TOPIC) _watch(log_);
            else if (log_.topic0 == UNWATCH_TOPIC) _stop(log_.topic1);
        } else if (log_.topic0 == SWAP_TOPIC && subscribed[log_.contractAddress]) {
            _onSwap(log_.contractAddress, log_.data);
        }
    }

    function watchedCount(address pool) external view returns (uint256) {
        return watched[pool].length;
    }

    // ---- internals ----

    function _onTick() internal {
        if (block.timestamp < uint256(lastReview) + reviewEvery) return;
        lastReview = uint64(block.timestamp);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: guard,
                gasLimit: REVIEW_GAS,
                payload: abi.encodeWithSignature("reviewByReactive(address)", address(0))
            })
        );
        emit ReviewRequested(uint64(block.timestamp));
    }

    function _watch(LogRecord calldata log_) internal {
        uint256 tokenId = log_.topic1;
        address pool = address(uint160(log_.topic2));
        (int24 tickLower, int24 tickUpper, uint32 grace) = abi.decode(log_.data, (int24, int24, uint32));
        if (positions[tokenId].active || watched[pool].length >= MAX_PER_POOL) return;
        positions[tokenId] = Position(pool, tickLower, tickUpper, grace, 0, true);
        watched[pool].push(tokenId);
        if (!subscribed[pool]) {
            subscribed[pool] = true;
            SYSTEM.subscribe(originChainId, pool, SWAP_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit Watching(tokenId, pool);
    }

    function _stop(uint256 tokenId) internal {
        Position storage p = positions[tokenId];
        if (!p.active) return;
        p.active = false;
        uint256[] storage list = watched[p.pool];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == tokenId) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit Stopped(tokenId);
    }

    function _onSwap(address pool, bytes calldata data) internal {
        // data: amount0, amount1, sqrtPriceX96, liquidity, tick
        (,,,, int24 tick) = abi.decode(data, (int256, int256, uint160, uint128, int24));
        uint256[] storage list = watched[pool];
        uint256 i = 0;
        while (i < list.length) {
            uint256 tokenId = list[i];
            Position storage p = positions[tokenId];
            bool inside = tick >= p.tickLower && tick < p.tickUpper;
            if (inside) {
                if (p.outSince != 0) {
                    p.outSince = 0;
                    emit CameBack(tokenId, tick);
                }
                i++;
            } else if (p.outSince == 0) {
                p.outSince = uint64(block.timestamp);
                emit WentOut(tokenId, tick);
                i++;
            } else if (block.timestamp - p.outSince >= p.grace) {
                uint64 outFor = uint64(block.timestamp) - p.outSince;
                p.active = false;
                list[i] = list[list.length - 1];
                list.pop(); // do not advance: the swapped-in entry is checked next
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: originChainId,
                        recipient: guard,
                        gasLimit: CALLBACK_GAS,
                        payload: abi.encodeWithSignature("closeByReactive(address,uint256)", address(0), tokenId)
                    })
                );
                emit CloseRequested(tokenId, tick, outFor);
            } else {
                i++;
            }
        }
    }
}
