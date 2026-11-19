// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {GuardMeter} from "../src/GuardMeter.sol";
import {GuardReactive} from "../src/GuardReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {INonfungiblePositionManager, ICLPool, IERC20} from "../src/interfaces/IAero.sol";
import {MockSystem} from "./GuardReactive.t.sol";

interface IERC20A {
    function approve(address, uint256) external returns (bool);
}

/// Three days of the whole loop on a fork of Base, with no mocked readings: the Reactive clock (run here
/// against a stand-in system contract) produces the exact callbacks it would send; each one is delivered
/// to the guard as the real callback proxy, with the clock's own address as the sender. Prices are moved
/// by real swaps. Whatever the guard decides comes from its own measurements.
contract LifecycleForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;
    address constant PROXY = 0xCc780DdE33f56f55dE778D42c930959374a4a068; // Reactive callback proxy on Base
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant TICK = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4; // Cron1000
    address constant CL50 = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH/USDC
    address constant CL100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24; // WETH/USDC
    address constant VIA = 0xD0Acf293547457Fb4fE9eE32CA93e89497626816; // AERO/USDC prices AERO

    PositionGuard guard;
    GuardMeter meter;
    GuardReactive clock;
    MockSystem sys;
    address user = makeAddr("user");
    uint256 t;
    uint256 delivered;
    uint256 maxGas;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        clock = new GuardReactive(8453);
        guard = new PositionGuard(NPM, AERO, PROXY, address(clock), SUGAR);
        meter = guard.meter();
        clock.setGuard(address(guard));
        clock.start(TICK, 1 hours, 1 days);
        t = vm.getBlockTimestamp();
    }

    /// One Cron1000 tick (~17 min): the clock may ask for a callback; deliver it as the proxy would.
    function _tick() internal {
        t += 17 minutes;
        vm.warp(t);
        IReactive.LogRecord memory l;
        l.contractAddress = CRON;
        l.topic0 = TICK;
        uint256 before = sys.reqCount();
        vm.prank(SYSTEM);
        clock.react(l);
        if (sys.reqCount() == before) return;
        ISystemContract.CallbackConfiguration_V_1_0 memory r = sys.req(before);
        assertEq(r.recipient, address(guard));
        // the proxy fills in the first argument with the reactive contract's address
        bytes memory payload = abi.encodePacked(bytes4(r.payload), abi.encode(address(clock)));
        uint256 g0 = gasleft();
        vm.prank(PROXY);
        (bool ok,) = address(guard).call{gas: r.gasLimit}(payload);
        uint256 used = g0 - gasleft();
        assertTrue(ok, "callback reverted");
        delivered++;
        if (used > maxGas) maxGas = used;
    }

    function _swing(bool up) internal {
        address who = makeAddr("trader");
        if (up) {
            deal(USDC, who, 3_000_000e6);
        } else {
            deal(WETH, who, 1_000e18);
        }
        vm.startPrank(who);
        Trader tr = new Trader();
        vm.stopPrank();
        if (up) deal(USDC, address(tr), 3_000_000e6);
        else deal(WETH, address(tr), 1_000e18);
        tr.swap(CL50, !up, up ? USDC : WETH);
        if (up) deal(USDC, address(tr), 3_000_000e6);
        else deal(WETH, address(tr), 1_000e18);
        tr.swap(CL100, !up, up ? USDC : WETH);
    }

    function test_threeDays_fromDepositToDecisions_onRealPools() public {
        deal(WETH, user, 1e18);
        deal(USDC, user, 3_000e6);
        vm.startPrank(user);
        IERC20A(WETH).approve(address(guard), type(uint256).max);
        IERC20A(USDC).approve(address(guard), type(uint256).max);
        uint256 id = guard.open(
            PositionGuard.OpenParams({
                pool: CL50,
                amount0: 1e18,
                amount1: 3_000e6,
                halfWidth: 20,
                amount0Min: 0,
                amount1Min: 0,
                stake: true,
                graceSeconds: 3 hours,
                maxLossBps: 300
            })
        );
        guard.setPricePool(id, VIA);
        guard.setNetExit(id, 10);
        address[] memory alts = new address[](1);
        alts[0] = CL100;
        guard.setAlternates(id, alts);
        vm.stopPrank();

        uint256 measuredAfter;
        for (uint256 i = 0; i < 3 * 85; i++) {
            if (i % 9 == 0) _swing(i % 18 == 0); // a swing up or down every ~2.5 hours
            _tick();
            if (measuredAfter == 0 && guard.reviewCount() > 0) {
                uint256 cur = guard.reviewList(0);
                (, bool m) = guard.netPerDay(cur);
                if (m) measuredAfter = i * 17;
            }
        }
        console2.log("callbacks delivered in 3 days:", delivered);
        console2.log("most gas one callback used:", maxGas);
        console2.log("net rule measured after (minutes):", measuredAfter);
        console2.log("snapshots of CL50 / CL100:", meter.snapsOf(CL50).length, meter.snapsOf(CL100).length);
        assertGe(delivered, 60, "a check every 68 min (four 17-min ticks) plus the daily reviews");
        assertLt(maxGas, 6_000_000, "every callback fits its gas limit");

        if (guard.reviewCount() == 0) {
            console2.log("outcome: the guard closed the position and sent everything back");
            assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user);
        } else {
            uint256 cur = guard.reviewList(0);
            (,, address pool,,,,) = guard.guarded(cur);
            (int256 net, bool m) = guard.netPerDay(cur);
            console2.log(cur == id ? "outcome: kept in the first pool" : "outcome: moved to the other pool");
            console2.log("pool:", pool);
            console2.log("net per day (1e18 = 100%):", net);
            console2.log("measured:", m);
        }
    }
}

contract Trader {
    function swap(address pool, bool zeroForOne, address tokenIn) external {
        ICLPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(IERC20(tokenIn).balanceOf(address(this)) / 20),
                zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                abi.encode(tokenIn)
            );
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address tk = abi.decode(data, (address));
        IERC20(tk).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }
}
