// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GuardReactive} from "../src/GuardReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// Stands in for Reactive's system contract at 0x8888…: records subscriptions and callback requests.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address c;
        uint256 topic0;
    }
    Sub[] public subs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal reqs;

    function subscribe(uint256 chainId, address c, uint256 topic0, uint256, uint256, uint256) external {
        subs.push(Sub(chainId, c, topic0));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external {
        reqs.push(cfg);
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function reqCount() external view returns (uint256) {
        return reqs.length;
    }

    function req(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return reqs[i];
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
    receive() external payable {}
}

contract GuardReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant BASE = 8453;
    address guard = makeAddr("guard");
    address pool = makeAddr("pool");
    GuardReactive rx;
    MockSystem sys;
    uint256 clock = 1_000_000; // explicit clock: with via-IR, block.timestamp read in a test can be stale after vm.warp
    uint256 WATCH; // cached: a getter call would use up vm.prank
    uint256 UNWATCH;
    uint256 SWAP;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        rx = new GuardReactive(BASE);
        rx.setGuard(guard);
        (WATCH, UNWATCH, SWAP) = (rx.WATCH_TOPIC(), rx.UNWATCH_TOPIC(), rx.SWAP_TOPIC());
        vm.warp(clock);
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _log(address c, uint256 t0, uint256 t1, uint256 t2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = BASE;
        l.contractAddress = c;
        l.topic0 = t0;
        l.topic1 = t1;
        l.topic2 = t2;
        l.data = data;
    }

    function _watch(uint256 id, int24 lo, int24 hi, uint32 grace) internal {
        vm.prank(SYSTEM);
        rx.react(_log(guard, WATCH, id, uint256(uint160(pool)), abi.encode(lo, hi, grace)));
    }

    function _swap(int24 tick) internal {
        vm.prank(SYSTEM);
        rx.react(_log(pool, SWAP, 0, 0, abi.encode(int256(1), int256(-1), uint160(1), uint128(1), tick)));
    }

    function test_setGuardSubscribesToGuardEvents() public view {
        assertEq(sys.subCount(), 2);
    }

    function test_watchSubscribesToPoolOnce() public {
        _watch(1, -100, 100, 3 hours);
        _watch(2, -200, 200, 3 hours);
        assertEq(sys.subCount(), 3, "one pool subscription for both positions");
        assertEq(rx.watchedCount(pool), 2);
    }

    function test_closesOnlyAfterGraceOutOfRange() public {
        _watch(1, -100, 100, 3 hours);
        _swap(0); // inside
        _swap(150); // goes out: clock starts
        _skip(2 hours);
        _swap(160); // still out, grace not over
        assertEq(sys.reqCount(), 0);
        _skip(61 minutes);
        _swap(170); // out for 3 h 1 min
        assertEq(sys.reqCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory r = sys.req(0);
        assertEq(r.chainId, BASE);
        assertEq(r.recipient, guard);
        assertEq(r.payload, abi.encodeWithSignature("closeByReactive(address,uint256)", address(0), uint256(1)));
        assertEq(rx.watchedCount(pool), 0, "no longer watched");
        _swap(180);
        assertEq(sys.reqCount(), 1, "asked once");
    }

    function test_comingBackResetsTheClock() public {
        _watch(1, -100, 100, 3 hours);
        _swap(150);
        _skip(2 hours);
        _swap(50); // back inside
        _skip(2 hours);
        _swap(150); // out again: a fresh clock
        _skip(2 hours);
        _swap(150);
        assertEq(sys.reqCount(), 0);
    }

    function test_upperBoundIsOutside_lowerIsInside() public {
        _watch(1, -100, 100, 1);
        _swap(-100);
        _skip(10);
        _swap(-100);
        assertEq(sys.reqCount(), 0, "tickLower is inside");
        _swap(100);
        _skip(10);
        _swap(100);
        assertEq(sys.reqCount(), 1, "tickUpper is outside");
    }

    function test_unwatchStops() public {
        _watch(1, -100, 100, 1);
        vm.prank(SYSTEM);
        rx.react(_log(guard, UNWATCH, 1, 0, ""));
        _swap(500);
        _skip(10);
        _swap(500);
        assertEq(sys.reqCount(), 0);
    }

    function test_twoPositionsOneClosesOtherStays() public {
        _watch(1, -100, 100, 1 hours);
        _watch(2, -1000, 1000, 1 hours);
        _swap(300);
        _skip(2 hours);
        _swap(300);
        assertEq(sys.reqCount(), 1);
        assertEq(rx.watchedCount(pool), 1);
    }

    function test_onlySystemCanReact() public {
        vm.expectRevert();
        rx.react(_log(guard, WATCH, 1, uint256(uint160(pool)), abi.encode(int24(-1), int24(1), uint32(1))));
    }

    function test_ignoresOtherChainsAndUnknownPools() public {
        _watch(1, -100, 100, 1);
        IReactive.LogRecord memory l =
            _log(pool, SWAP, 0, 0, abi.encode(int256(1), int256(-1), uint160(1), uint128(1), int24(500)));
        l.chainId = 1;
        vm.prank(SYSTEM);
        rx.react(l);
        _skip(10);
        vm.prank(SYSTEM);
        rx.react(l);
        assertEq(sys.reqCount(), 0);
    }
}
