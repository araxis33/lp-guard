// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title GuardReactive
/// @notice Lives on Reactive Network and is the guard's clock. It wakes up on a Reactive Cron event
///         and asks the PositionGuard on Base, through a callback, for one of two things:
///         - once a day, the review of every position (`reviewByReactive`);
///         - every hour in between, the check (`checkByReactive`): price snapshots, and the close of a
///           position whose price has stayed out of range for its grace period.
///
///         It does not listen to the pools' swaps: a reaction is paid for in REACT, and a busy pool
///         swaps thousands of times a day. The guard reads prices on Base itself.
///
///         It never holds user funds. Its deployer can point it at a new guard, switch the clock on
///         or off, and take back the REACT it holds, so nothing is stuck when the guard is replaced.
contract GuardReactive is AbstractReactive {
    /// @notice Reactive Network's system contract that emits the Cron timer events.
    address public constant CRON = 0x0000000000000000000000000000000000fffFfF;
    /// @notice Gas for the daily review callback (two positions, one closing: ~1.13M on a Base fork).
    uint64 public constant REVIEW_GAS = 3_500_000;
    /// @notice Gas for the hourly check callback: up to two positions at 1.3M each (one ~0.17M).
    uint64 public constant CHECK_GAS = 3_000_000;

    uint256 public immutable originChainId;
    address public immutable deployer;
    /// @notice The PositionGuard on the origin chain that the callbacks go to.
    address public guard;
    /// @notice topic0 of the Cron event this contract wakes up on; 0 while the clock is off.
    uint256 public cronTopic;
    /// @notice How often the check and the review run, in seconds.
    uint32 public checkEvery;
    uint32 public reviewEvery;
    /// @notice When the last check and the last review were asked for.
    uint64 public lastCheck;
    uint64 public lastReview;

    event GuardSet(address guard);
    event ClockStarted(uint256 cronTopic, uint32 checkEvery, uint32 reviewEvery);
    event ClockStopped();
    event CheckRequested(uint64 at);
    event ReviewRequested(uint64 at);
    event Withdrawn(address to, uint256 amount);

    error NotDeployer();
    error GuardNotSet();
    error ClockRunning();
    error BadPeriod();

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert NotDeployer();
        _;
    }

    constructor(uint256 originChainId_) payable {
        originChainId = originChainId_;
        deployer = msg.sender;
    }

    /// @notice Point the callbacks at a guard. The guard is deployed after this contract (it needs
    ///         this contract's address), and a later version of the guard can take over the same
    ///         clock and the same REACT.
    function setGuard(address guard_) external onlyDeployer {
        guard = guard_;
        emit GuardSet(guard_);
    }

    /// @notice Switch the clock on: wake up on the Cron event `cronTopic_` (every tick is paid for,
    ///         so take the slowest one that is at least as frequent as `checkEvery_`).
    function start(uint256 cronTopic_, uint32 checkEvery_, uint32 reviewEvery_) external onlyDeployer {
        if (guard == address(0)) revert GuardNotSet();
        if (cronTopic != 0) revert ClockRunning();
        if (checkEvery_ == 0 || reviewEvery_ < checkEvery_) revert BadPeriod();
        cronTopic = cronTopic_;
        checkEvery = checkEvery_;
        reviewEvery = reviewEvery_;
        SYSTEM.subscribe(block.chainid, CRON, cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ClockStarted(cronTopic_, checkEvery_, reviewEvery_);
    }

    /// @notice Switch the clock off: no more ticks, so no more REACT spent.
    function stop() external onlyDeployer {
        uint256 topic = cronTopic;
        if (topic == 0) return;
        cronTopic = 0;
        SYSTEM.unsubscribe(block.chainid, CRON, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ClockStopped();
    }

    /// @notice Take back REACT this contract holds, after settling what it owes the system contract.
    function withdraw(address payable to, uint256 amount) external onlyDeployer {
        _coverDebt();
        _pay(to, amount);
        emit Withdrawn(to, amount);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.contractAddress != CRON || cronTopic == 0 || log_.topic0 != cronTopic) return;
        uint64 now_ = uint64(block.timestamp);
        if (now_ >= lastReview + reviewEvery) {
            // the review keeps snapshots too, so it stands in for that hour's check
            lastReview = now_;
            lastCheck = now_;
            _callback(REVIEW_GAS, "reviewByReactive(address)");
            emit ReviewRequested(now_);
        } else if (now_ >= lastCheck + checkEvery) {
            lastCheck = now_;
            _callback(CHECK_GAS, "checkByReactive(address)");
            emit CheckRequested(now_);
        }
    }

    function _callback(uint64 gas, string memory sig) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: guard,
                gasLimit: gas,
                payload: abi.encodeWithSignature(sig, address(0))
            })
        );
    }
}
