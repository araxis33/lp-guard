// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GuardReactive} from "../src/GuardReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// Stands in for Reactive's system contract at 0x8888…: records subscriptions and callback requests.
contract MockSystem {
    uint256 public subs;
    uint256 public unsubs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal reqs;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subs++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubs++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) external {
        reqs.push(cfg);
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
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant BASE = 8453;
    uint256 constant TICK = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    address guard = makeAddr("guard");
    GuardReactive rx;
    MockSystem sys;
    uint256 clock = 1_000_000;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        rx = new GuardReactive{value: 10 ether}(BASE);
        rx.setGuard(guard);
        rx.start(TICK, 1 hours, 1 days);
        vm.warp(clock);
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _tick() internal {
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = CRON;
        l.topic0 = TICK;
        vm.prank(SYSTEM);
        rx.react(l);
    }

    function _payload(uint256 i) internal view returns (bytes memory) {
        return sys.req(i).payload;
    }

    function test_firstTick_runsTheReview_thenHourlyChecks_thenTheNextReview() public {
        _tick();
        assertEq(sys.reqCount(), 1);
        assertEq(_payload(0), abi.encodeWithSignature("reviewByReactive(address)", address(0)));
        assertEq(sys.req(0).recipient, guard);
        assertEq(sys.req(0).chainId, BASE);

        _skip(17 minutes);
        _tick();
        assertEq(sys.reqCount(), 1, "not within the hour");

        _skip(43 minutes);
        _tick();
        assertEq(sys.reqCount(), 2);
        assertEq(_payload(1), abi.encodeWithSignature("checkByReactive(address)", address(0)));

        for (uint256 i = 0; i < 22; i++) {
            _skip(1 hours);
            _tick();
        }
        assertEq(sys.reqCount(), 24, "23 checks and a review in the first day");
        _skip(1 hours);
        _tick();
        assertEq(_payload(24), abi.encodeWithSignature("reviewByReactive(address)", address(0)), "next day's review");
    }

    function test_ignoresOtherEvents() public {
        IReactive.LogRecord memory l;
        l.contractAddress = makeAddr("pool");
        l.topic0 = TICK;
        vm.prank(SYSTEM);
        rx.react(l);
        assertEq(sys.reqCount(), 0);
    }

    function test_onlyTheSystemCanReact() public {
        IReactive.LogRecord memory l;
        l.contractAddress = CRON;
        l.topic0 = TICK;
        vm.expectRevert();
        rx.react(l);
    }

    function test_stop_endsTheTicks_andCanStartAgain() public {
        rx.stop();
        assertEq(sys.unsubs(), 1);
        _tick();
        assertEq(sys.reqCount(), 0, "clock off: nothing asked, nothing spent on callbacks");
        rx.start(TICK, 1 hours, 1 days);
        _tick();
        assertEq(sys.reqCount(), 1);
    }

    function test_deployerOnly() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(GuardReactive.NotDeployer.selector);
        rx.setGuard(stranger);
        vm.expectRevert(GuardReactive.NotDeployer.selector);
        rx.stop();
        vm.expectRevert(GuardReactive.NotDeployer.selector);
        rx.withdraw(payable(stranger), 1);
        vm.expectRevert(GuardReactive.NotDeployer.selector);
        rx.start(TICK, 1 hours, 1 days);
        vm.stopPrank();
    }

    function test_withdraw_givesTheReactBack() public {
        address payable to = payable(makeAddr("owner"));
        rx.withdraw(to, 4 ether);
        assertEq(to.balance, 4 ether);
        assertEq(address(rx).balance, 6 ether);
    }

    function test_setGuard_movesTheClockToANewGuard() public {
        address next = makeAddr("guardV2");
        rx.setGuard(next);
        _tick();
        assertEq(sys.req(0).recipient, next);
    }

    function test_start_checksItsArguments() public {
        rx.stop();
        vm.expectRevert(GuardReactive.BadPeriod.selector);
        rx.start(TICK, 0, 1 days);
        vm.expectRevert(GuardReactive.BadPeriod.selector);
        rx.start(TICK, 2 days, 1 days);
        rx.start(TICK, 1 hours, 1 days);
        vm.expectRevert(GuardReactive.ClockRunning.selector);
        rx.start(TICK, 1 hours, 1 days);
    }
}
