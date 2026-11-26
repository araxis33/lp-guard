// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IGuard, GuardDeploy} from "./GuardAll.sol";
import {GuardCore} from "../src/GuardCore.sol";
import {GuardMeter} from "../src/GuardMeter.sol";
import {GuardExt} from "../src/GuardExt.sol";
import {PoolMath} from "../src/lib/PoolMath.sol";
import {INonfungiblePositionManager, ICLPool, IERC20} from "../src/interfaces/IAero.sol";

interface IERC20A {
    function approve(address, uint256) external returns (bool);
}

/// v1.2 on a fork of Base: the guard picks the pool on entry, parks the coins of a position it closes
/// by itself, gives them back at any moment, and puts them back into a pool that pays again.
contract ParkForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;
    address constant CL50 = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH/USDC, step 50
    address constant CL100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24; // WETH/USDC, step 100
    address constant AERO_USDC = 0xD0Acf293547457Fb4fE9eE32CA93e89497626816; // prices AERO in USDC

    IGuard guard;
    GuardMeter meter;
    address user = makeAddr("user");
    address other = makeAddr("other");
    address stranger = makeAddr("stranger");
    address proxy = makeAddr("proxy");
    address reactive = makeAddr("reactive");
    uint256 clock;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = GuardDeploy.deploy(NPM, AERO, proxy, reactive, SUGAR);
        meter = guard.meter();
        clock = vm.getBlockTimestamp();
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _params(uint256 weth, uint256 usdc, uint16 halfWidth, bool reenter)
        internal
        pure
        returns (GuardCore.OpenParams memory p)
    {
        address[] memory alts = new address[](1);
        alts[0] = CL100;
        p = GuardCore.OpenParams({
            pool: CL50,
            amount0: weth,
            amount1: usdc,
            halfWidth: halfWidth,
            amount0Min: 0,
            amount1Min: 0,
            stake: true,
            graceSeconds: 3 hours,
            maxLossBps: 0,
            alternates: alts,
            pricePool: AERO_USDC,
            reenter: reenter,
            exitToken: address(0)
        });
    }

    function _openAs(address who, GuardCore.OpenParams memory p) internal returns (uint256 id) {
        deal(WETH, who, p.amount0);
        deal(USDC, who, p.amount1);
        vm.startPrank(who);
        IERC20A(WETH).approve(address(guard), type(uint256).max);
        IERC20A(USDC).approve(address(guard), type(uint256).max);
        id = guard.open(p);
        vm.stopPrank();
    }

    /// Sells WETH (token0) into CL50 until its price is far below a narrow range, then lets the
    /// hourly check run past the grace period: the guard closes the position by itself.
    function _closedByItself(uint256 id) internal {
        _closedByItself(id, 3_000e18);
    }

    /// The same with a sale of `weth` (a realistic fall leaves USDC in the pool to swap into).
    function _closedByItself(uint256 id, uint256 weth) internal {
        Seller s = new Seller();
        deal(WETH, address(s), weth);
        (, int24 before,,,,) = ICLPool(CL50).slot0();
        s.sell(CL50, WETH);
        (, int24 afterTick,,,,) = ICLPool(CL50).slot0();
        console2.log("CL50 pushed down by ticks:", int256(before) - int256(afterTick));
        _skip(31 minutes);
        _check();
        _skip(3 hours);
        uint256 g0 = gasleft();
        _check();
        console2.log("gas for the hourly check that closes:", g0 - gasleft());
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "closed by the hourly check");
    }

    function _check() internal {
        vm.prank(proxy);
        guard.checkByReactive{gas: 3_000_000}(reactive);
    }

    function _reviewRun() internal {
        vm.prank(proxy);
        guard.reviewByReactive{gas: 6_000_000}(reactive);
    }

    // ---- entry: the guard picks the pool ----

    function test_entry_nothingMeasured_opensInTheFirstPool_otherBecomesAlternate() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 20, true));
        (,, address pool,,,,) = guard.guarded(id);
        assertEq(pool, CL50, "nothing measured yet: the owner's first pool");
        address[] memory alts = guard.alternatesOf(id);
        assertEq(alts.length, 1);
        assertEq(alts[0], CL100);
        assertTrue(guard.reenterOn(id));
        assertEq(guard.pricePool(id), AERO_USDC);
    }

    /// Both pools measured for real (12 h of pay readings, hourly price snapshots, nothing mocked):
    /// the position opens in the one the meter says earns more, whatever the order they were given in.
    function test_entry_measuredPools_opensInTheOneThatEarnsMore() public {
        meter.markPay(CL50);
        meter.markPay(CL100);
        for (uint256 i = 0; i < 13; i++) {
            meter.snap(CL50);
            meter.snap(CL100);
            _skip(1 hours);
        }
        meter.markPay(CL50);
        meter.markPay(CL100);
        int24 half = 20 * 50;
        int256 n50 = meter.netRate(CL50, half, AERO_USDC);
        int256 n100 = meter.netRate(CL100, half, AERO_USDC);
        console2.log("net per day, 1e18 = 100%: CL50 / CL100");
        console2.logInt(n50 * 1 days);
        console2.logInt(n100 * 1 days);
        assertTrue(meter.measured(CL50) && meter.measured(CL100), "both measured");
        address better = n100 > n50 ? CL100 : CL50;
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 20, false));
        (,, address pool,,,,) = guard.guarded(id);
        assertEq(pool, better, "opened in the pool that earns more");
    }

    function test_entry_alternatesWithoutAPriceForAero_refused() public {
        GuardCore.OpenParams memory p = _params(0.1e18, 300e6, 20, true);
        p.pricePool = address(0);
        deal(WETH, user, 1e18);
        deal(USDC, user, 300e6);
        vm.startPrank(user);
        IERC20A(WETH).approve(address(guard), type(uint256).max);
        IERC20A(USDC).approve(address(guard), type(uint256).max);
        vm.expectRevert(GuardCore.BadPricePool.selector);
        guard.open(p);
        vm.stopPrank();
    }

    function test_entry_atMostFourOnTheGuard() public {
        for (uint256 i = 0; i < 4; i++) {
            _openAs(user, _params(0.01e18, 30e6, 20, false));
        }
        GuardCore.OpenParams memory p = _params(0.01e18, 30e6, 20, false);
        deal(WETH, user, 0.01e18);
        deal(USDC, user, 30e6);
        vm.prank(user);
        vm.expectRevert(GuardCore.Full.selector);
        guard.open(p);
    }

    // ---- parking ----

    function test_park_closeByItself_keepsCoinsForTheOwner_AeroStillPaid() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 u0 = IERC20(USDC).balanceOf(user);
        _skip(1 hours); // earn some AERO
        uint256 aero0 = IERC20(AERO).balanceOf(user);
        _closedByItself(id);

        (address owner, uint64 at, address t0, address t1, uint128 b0, uint128 b1, int24 half,, bool stake) =
            guard.parked(id);
        assertEq(owner, user, "parked for the owner");
        assertEq(at, uint64(clock));
        assertEq(t0, WETH);
        assertEq(t1, USDC);
        assertTrue(b0 > 0 || b1 > 0, "coins kept");
        assertTrue(stake);
        assertGt(half, 0);
        console2.log("parked WETH / USDC:", b0, b1);
        assertEq(IERC20(WETH).balanceOf(user), w0, "no WETH sent out");
        assertEq(IERC20(USDC).balanceOf(user), u0, "no USDC sent out");
        assertGe(IERC20(AERO).balanceOf(user), aero0, "AERO still goes to the owner");
        assertEq(guard.parkedTotal(WETH), b0);
        assertEq(guard.parkedTotal(USDC), b1);
        assertGe(IERC20(WETH).balanceOf(address(guard)), b0, "the guard holds the parked WETH");
        assertGe(IERC20(USDC).balanceOf(address(guard)), b1, "the guard holds the parked USDC");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user, "empty NFT back to the owner");
        assertEq(guard.reviewCount(), 1, "the parked plan stays on the list");
        address[] memory pools = guard.alternatesOf(id);
        assertEq(pools.length, 2, "every pool it may go back to: the alternate and its old pool");
    }

    function test_park_reenterOff_sendsEverythingOut_likeV11() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, false));
        uint256 w0 = IERC20(WETH).balanceOf(user);
        _closedByItself(id);
        (address owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, address(0), "nothing parked");
        assertGt(IERC20(WETH).balanceOf(user), w0, "coins to the owner");
        assertEq(guard.reviewCount(), 0);
    }

    function test_takeParked_ownerAnyTime_strangerNever() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        (,,,, uint128 b0, uint128 b1,,,) = guard.parked(id);
        vm.prank(stranger);
        vm.expectRevert(GuardCore.NotOwner.selector);
        guard.takeParked(id);

        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 u0 = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        guard.takeParked(id);
        assertEq(IERC20(WETH).balanceOf(user) - w0, b0, "all parked WETH");
        assertEq(IERC20(USDC).balanceOf(user) - u0, b1, "all parked USDC");
        assertEq(guard.parkedTotal(WETH), 0);
        assertEq(guard.parkedTotal(USDC), 0);
        assertEq(guard.reviewCount(), 0, "off the list");
        (address owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, address(0));
        vm.prank(user);
        vm.expectRevert(GuardCore.NotOwner.selector);
        guard.takeParked(id); // not twice
    }

    function test_takeParked_worksEvenWhenThePoolsCannotBeRead() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        vm.mockCallRevert(CL50, bytes(""), bytes("down"));
        vm.mockCallRevert(CL100, bytes(""), bytes("down"));
        vm.mockCallRevert(address(meter), bytes(""), bytes("down"));
        vm.prank(user);
        guard.takeParked(id);
        assertEq(guard.parkedTotal(WETH), 0);
    }

    /// Codex 26.11 (1): coins parked for one owner never leave with another owner's entry.
    function test_park_anotherOwnersEntry_cannotTouchParkedCoins() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        (,,,, uint128 b0, uint128 b1,,,) = guard.parked(id);
        // another owner enters with WETH only into CL100 (CL50 is pushed)
        GuardCore.OpenParams memory p = _params(0.2e18, 0, 20, false);
        p.pool = CL100;
        p.alternates = new address[](0);
        uint256 id2 = _openAs(other, p);
        assertGt(id2, 0);
        assertGe(IERC20(WETH).balanceOf(address(guard)), b0, "parked WETH still there");
        assertGe(IERC20(USDC).balanceOf(address(guard)), b1, "parked USDC still there");
        // and the other owner's own leftovers went back to them, not to the parked plan
        assertEq(guard.parkedTotal(WETH), b0);
        vm.prank(other);
        guard.close(id2);
        assertGe(IERC20(WETH).balanceOf(address(guard)), b0, "still there after their close");
        vm.prank(user);
        guard.takeParked(id);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "nothing left behind");
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0, "nothing left behind");
    }

    function test_park_theEmptyNftCannotComeBackIn() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        vm.startPrank(user);
        INonfungiblePositionManager(NPM).approve(address(guard), id);
        vm.expectRevert(GuardCore.IsParked.selector);
        guard.deposit(id, true, 0);
        vm.stopPrank();
    }

    // ---- going back in ----

    function _cl100Pays() internal {
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.bestAlternate.selector), abi.encode(CL100));
    }

    function test_reenter_twoReadingsTwentyHoursApart_thenBackIntoThePoolThatPays() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        _cl100Pays();
        _skip(1 days);
        _reviewRun();
        assertEq(guard.moveVote(id), CL100, "first reading: a vote");
        (address owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, user, "still parked");

        _skip(10 hours);
        _reviewRun();
        (owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, user, "not before 20 hours");

        _skip(11 hours);
        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 u0 = IERC20(USDC).balanceOf(user);
        vm.recordLogs();
        uint256 g0 = gasleft();
        _reviewRun();
        console2.log("gas for a daily run that goes back in:", g0 - gasleft());
        (owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, address(0), "no longer parked");
        uint256 newId = guard.reviewList(0);
        (address o, address gauge, address pool,,,,) = guard.guarded(newId);
        assertEq(o, user, "same owner");
        assertEq(pool, CL100, "in the pool that pays");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(newId), gauge, "staked");
        assertTrue(guard.reenterOn(newId), "keeps parking");
        (uint32 grace,) = guard.rangeWatch(newId);
        assertEq(grace, 3 hours, "keeps its grace");
        address[] memory alts = guard.alternatesOf(newId);
        assertEq(alts.length, 1);
        assertEq(alts[0], CL50, "the other pool is the alternate");
        assertEq(guard.parkedTotal(WETH), 0);
        assertEq(guard.parkedTotal(USDC), 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "nothing left on the guard");
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0, "nothing left on the guard");
        console2.log(
            "leftover to owner WETH / USDC:", IERC20(WETH).balanceOf(user) - w0, IERC20(USDC).balanceOf(user) - u0
        );
    }

    function test_reenter_noPoolPays_staysParked() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.bestAlternate.selector), abi.encode(address(0)));
        _skip(1 days);
        _reviewRun();
        _skip(1 days);
        _reviewRun();
        (address owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, user, "stays parked while no pool pays");
        assertEq(guard.moveVote(id), address(0));
    }

    function test_reenter_poolBeingPushed_failsWhole_staysParked_waitsAgain() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        (,,,, uint128 b0, uint128 b1,,,) = guard.parked(id);
        _cl100Pays();
        _skip(1 days);
        _reviewRun();
        _skip(21 hours);
        Seller s = new Seller();
        deal(WETH, address(s), 5_000e18);
        s.sell(CL100, WETH); // someone pushes CL100 right before the run
        vm.expectEmit(true, false, false, false, address(guard));
        emit GuardCore.ReenterFailed(id);
        _reviewRun();
        (address owner,,,, uint128 c0, uint128 c1,,,) = guard.parked(id);
        assertEq(owner, user, "still parked");
        assertEq(c0, b0, "WETH untouched");
        assertEq(c1, b1, "USDC untouched");
        assertGe(IERC20(WETH).balanceOf(address(guard)), b0);
    }

    function test_parked_hourlyCheck_snapsItsPools_withinGas() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(id);
        uint256 n = meter.snapsOf(CL100).length;
        _skip(1 hours);
        uint256 g0 = gasleft();
        _check();
        console2.log("gas for the hourly check of a parked plan:", g0 - gasleft());
        assertEq(meter.snapsOf(CL100).length, n + 1, "its pools keep being measured");
        id;
    }

    function test_parked_and_active_bothFitTheDailyRun() public {
        uint256 a = _openAs(user, _params(0.1e18, 300e6, 2, true));
        _closedByItself(a);
        GuardCore.OpenParams memory p = _params(0.1e18, 300e6, 20, false);
        p.pool = CL100;
        p.alternates = new address[](0);
        uint256 b = _openAs(other, p);
        _cl100Pays();
        _skip(1 days);
        _reviewRun();
        _skip(21 hours);
        _reviewRun(); // the parked plan goes back in while the other position is reviewed
        (address owner,,,,,,,,) = guard.parked(a);
        assertEq(owner, address(0), "went back in within 6M gas next to another position");
        (address ob,,,,,,) = guard.guarded(b);
        assertEq(ob, other, "the other position is untouched");
    }

    // ---- Codex 26.11 code review ----

    /// A position that left its range holds one token: a move must swap half of it first, not fail.
    function test_move_ofAOneSidedPosition_rebalancesAndOpens() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 2, false));
        Seller s = new Seller();
        deal(WETH, address(s), 3_000e18);
        s.sell(CL50, WETH); // CL50 far below the range: the position is all WETH
        _skip(31 minutes);
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.measured.selector), abi.encode(true));
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.netRate.selector), abi.encode(int256(0)));
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.bestAlternate.selector), abi.encode(CL100));
        vm.mockCall(
            address(meter), abi.encodeWithSelector(GuardMeter.netPerDay.selector), abi.encode(int256(1e15), true)
        );
        // the two pools' averages must agree for a move: let CL100 read like CL50 now
        vm.mockCall(CL50, abi.encodeWithSelector(ICLPool.observe.selector), _observeLike(CL100));
        vm.mockCall(CL50, abi.encodeWithSelector(ICLPool.slot0.selector), _slot0Like(CL100));
        vm.prank(user);
        guard.review(id);
        _skip(21 hours);
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "moved");
        (,, address pool,,,,) = guard.guarded(guard.reviewList(0));
        assertEq(pool, CL100, "opened in CL100 from one token");
    }

    function _observeLike(address pool) internal view returns (bytes memory) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        (int56[] memory c, uint160[] memory l) = ICLPool(pool).observe(ago);
        return abi.encode(c, l);
    }

    function _slot0Like(address pool) internal view returns (bytes memory) {
        (uint160 a, int24 b, uint16 c, uint16 d, uint16 e, bool f) = ICLPool(pool).slot0();
        return abi.encode(a, b, c, d, e, f);
    }

    function test_reenter_needsStaking() public {
        GuardCore.OpenParams memory p = _params(0.1e18, 300e6, 20, true);
        p.stake = false;
        deal(WETH, user, 0.1e18);
        deal(USDC, user, 300e6);
        vm.startPrank(user);
        IERC20A(WETH).approve(address(guard), type(uint256).max);
        IERC20A(USDC).approve(address(guard), type(uint256).max);
        vm.expectRevert(GuardCore.BadLimit.selector);
        guard.open(p);
        vm.stopPrank();
    }

    function test_reenter_withoutAPriceForAero_refused() public {
        GuardCore.OpenParams memory p = _params(0.1e18, 300e6, 20, true);
        p.alternates = new address[](0);
        p.pricePool = address(0);
        deal(WETH, user, 0.1e18);
        deal(USDC, user, 300e6);
        vm.startPrank(user);
        IERC20A(WETH).approve(address(guard), type(uint256).max);
        IERC20A(USDC).approve(address(guard), type(uint256).max);
        vm.expectRevert(GuardCore.BadPricePool.selector);
        guard.open(p);
        p.reenter = false;
        uint256 id = guard.open(p);
        vm.expectRevert(GuardCore.BadPricePool.selector);
        guard.setReenter(id, true);
        vm.stopPrank();
    }

    /// A pay reading that fails now is "not measured", never "pays nothing" (no exit on it).
    function test_netPerDay_currentPayUnreadable_notMeasured() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 20, false));
        for (uint256 i = 0; i < 13; i++) {
            _skip(1 hours);
            _check();
        }
        vm.prank(user);
        guard.review(id);
        (, bool ok) = guard.netPerDay(id);
        address gauge = ICLPool(CL50).gauge();
        vm.mockCallRevert(gauge, abi.encodeWithSignature("voter()"), bytes("down"));
        vm.mockCall(CL50, abi.encodeWithSignature("lastUpdated()"), abi.encode(uint48(clock - 1)));
        (, bool ok2) = guard.netPerDay(id);
        assertFalse(ok2, "unreadable pay: not measured");
        ok;
    }

    function test_open_straightOnTheExtension_refused() public {
        address ext = guard.ext();
        deal(USDC, user, 300e6);
        vm.startPrank(user);
        IERC20A(USDC).approve(ext, type(uint256).max);
        vm.expectRevert(GuardCore.NotGuarded.selector);
        GuardExt(payable(ext)).open(_params(0, 300e6, 20, true));
        vm.stopPrank();
    }

    function test_pricePool_cannotBeClearedWhileCoinsWouldBeParked() public {
        uint256 id = _openAs(user, _params(0.1e18, 300e6, 20, true));
        vm.prank(user);
        vm.expectRevert(GuardCore.BadPricePool.selector);
        guard.setPricePool(id, address(0));
    }

    // ---- exit into USDC (his 26.11: "WETH may keep falling, USDC holds") ----

    uint256 constant FALL = 1_200e18; // WETH sold into CL50: -536 ticks (~5.5%), USDC left in the pool

    function _usdcExit(uint16 halfWidth, bool reenter) internal pure returns (GuardCore.OpenParams memory p) {
        p = _params(0.1e18, 300e6, halfWidth, reenter);
        p.exitToken = USDC;
    }

    function test_exitToken_parkedInUsdc_afterAFall() public {
        uint256 id = _openAs(user, _usdcExit(1, true));
        _closedByItself(id, FALL);
        (address owner,,,, uint128 b0, uint128 b1,,,) = guard.parked(id);
        assertEq(owner, user);
        assertEq(b0, 0, "no WETH kept: it was swapped into USDC");
        assertGt(b1, 0, "parked in USDC");
        console2.log("parked USDC after the fall:", b1);
        assertEq(guard.parkedTotal(WETH), 0);
        assertEq(guard.parkedTotal(USDC), b1);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "nothing in WETH on the guard");
    }

    function test_exitToken_reenterOff_ownerGetsUsdcOnly() public {
        uint256 id = _openAs(user, _usdcExit(1, false));
        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 u0 = IERC20(USDC).balanceOf(user);
        _closedByItself(id, FALL);
        assertEq(IERC20(WETH).balanceOf(user), w0, "no WETH to the owner");
        assertGt(IERC20(USDC).balanceOf(user), u0, "USDC to the owner");
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
    }

    function test_exitToken_ownerClose_paysUsdc() public {
        uint256 id = _openAs(user, _usdcExit(20, false));
        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 u0 = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        guard.close(id);
        uint256 got = IERC20(USDC).balanceOf(user) - u0;
        console2.log("in: 0.1 WETH + 300 USDC (refunds already back); out USDC:", got);
        assertEq(IERC20(WETH).balanceOf(user), w0, "no WETH");
        assertGt(got, 0);
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
    }

    function test_exitToken_swapFails_closeStillHappens_twoTokens() public {
        uint256 id = _openAs(user, _usdcExit(20, false));
        uint256 w0 = IERC20(WETH).balanceOf(user);
        vm.mockCallRevert(CL50, abi.encodeWithSelector(ICLPool.swap.selector), bytes("pushed"));
        vm.expectEmit(true, false, false, false, address(guard));
        emit GuardCore.ExitSwapFailed(id);
        vm.prank(user);
        guard.close(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "closed anyway");
        assertGt(IERC20(WETH).balanceOf(user), w0, "WETH as it came out");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
    }

    function test_exitToken_reentersFromUsdcOnly() public {
        uint256 id = _openAs(user, _usdcExit(1, true));
        _closedByItself(id, FALL);
        _cl100Pays();
        _skip(1 days);
        _reviewRun();
        _skip(21 hours);
        _reviewRun();
        (address owner,,,,,,,,) = guard.parked(id);
        assertEq(owner, address(0), "went back in from USDC alone");
        uint256 newId = guard.reviewList(0);
        (,, address pool,,,,) = guard.guarded(newId);
        assertEq(pool, CL100);
        assertEq(guard.exitToken(newId), USDC, "keeps exiting into USDC");
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
    }

    function test_exitToken_mustBeOneOfThePair() public {
        GuardCore.OpenParams memory p = _usdcExit(20, false);
        p.exitToken = AERO;
        deal(WETH, user, 0.1e18);
        deal(USDC, user, 300e6);
        vm.startPrank(user);
        IERC20A(WETH).approve(address(guard), type(uint256).max);
        IERC20A(USDC).approve(address(guard), type(uint256).max);
        vm.expectRevert(GuardCore.BadSwapPool.selector);
        guard.open(p);
        vm.stopPrank();
    }

    /// Codex 26.11 (3): a swap that stops at the price limit with part unsold is a failed exit swap,
    /// reported as such, and the owner gets both coins as they came out.
    function test_exitToken_partialSwap_isAFailure_bothCoinsToOwner() public {
        GuardCore.OpenParams memory p = _usdcExit(20, false);
        p.amount0 = 100e18;
        p.amount1 = 300_000e6;
        uint256 id = _openAs(user, p);
        Seller s = new Seller();
        deal(WETH, address(s), 420e18);
        s.sell(CL50, WETH); // ~90 ticks below the 30-minute average: the limit is 10 ticks away
        uint256 w0 = IERC20(WETH).balanceOf(user);
        vm.expectEmit(true, false, false, false, address(guard));
        emit GuardCore.ExitSwapFailed(id);
        vm.prank(user);
        guard.close(id);
        assertGt(IERC20(WETH).balanceOf(user), w0, "WETH as it came out");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0);
    }
}

/// Sells WETH (token0 of WETH/USDC) into a pool to push its price down.
contract Seller {
    function sell(address pool, address weth) external {
        ICLPool(pool)
            .swap(address(this), true, int256(IERC20(weth).balanceOf(address(this))), 4295128740, abi.encode(weth));
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address t = abi.decode(data, (address));
        IERC20(t).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }
}
