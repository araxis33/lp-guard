// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {IGuard, GuardDeploy} from "./GuardAll.sol";
import {GuardCore} from "../src/GuardCore.sol";
import {ICLPool, ICLGauge, ILeafVoter, IERC20} from "../src/interfaces/IAero.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// Measuring how much a pool pays, on a fork of Base: the two WETH/USDC Slipstream pools
/// (price step 50 and 100) are the same pair, so a position could move between them.
contract PayForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CL50 = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH/USDC step 50
    address constant CL100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24; // WETH/USDC step 100
    address constant AERO_WETH = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // another pair
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;

    IGuard guard;
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = GuardDeploy.deploy(NPM, AERO, makeAddr("proxy"), makeAddr("reactive"), SUGAR);
    }

    function _open() internal returns (uint256 id) {
        deal(WETH, user, 1e18);
        deal(USDC, user, 5_000e6);
        vm.startPrank(user);
        IERC20Approve(WETH).approve(address(guard), type(uint256).max);
        IERC20Approve(USDC).approve(address(guard), type(uint256).max);
        id = guard.open(
            GuardCore.OpenParams({
                pool: CL100,
                amount0: 1e18,
                amount1: 5_000e6,
                halfWidth: 5,
                amount0Min: 0,
                amount1Min: 0,
                stake: true,
                graceSeconds: 0,
                maxLossBps: 0,
                alternates: new address[](0),
                pricePool: address(0),
                reenter: false
            })
        );
        vm.stopPrank();
    }

    /// Pretends `pool` has nothing accrued since its last settlement (or `extra` AERO), so a test
    /// controls what the guard reads instead of the fork's real emissions over a warp.
    function _unsettled(address pool, uint256 extra) internal {
        address gauge = ICLPool(pool).gauge();
        address voter = ICLGauge(gauge).voter();
        uint256 settled = ICLGauge(gauge).lastCumulativeRewardShare();
        vm.mockCall(
            voter, abi.encodeCall(ILeafVoter.projectedCumulativeRewardShare, (gauge)), abi.encode(settled + extra)
        );
    }

    function _alts(address a) internal pure returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = a;
    }

    // ---- naming the pools a position may move into ----

    function test_setAlternates_ownerNamesAPoolOfTheSamePair() public {
        uint256 id = _open();
        vm.prank(user);
        guard.setAlternates(id, _alts(CL50));
        assertEq(guard.alternatesOf(id).length, 1);
        assertEq(guard.alternatesOf(id)[0], CL50);
    }

    function test_setAlternates_onlyOwner() public {
        uint256 id = _open();
        vm.prank(stranger);
        vm.expectRevert(GuardCore.NotOwner.selector);
        guard.setAlternates(id, _alts(CL50));
    }

    function test_setAlternates_refusesAnotherPairOrTheSamePool() public {
        uint256 id = _open();
        vm.startPrank(user);
        vm.expectRevert(GuardCore.NotSamePair.selector);
        guard.setAlternates(id, _alts(AERO_WETH));
        vm.expectRevert(GuardCore.NotSamePair.selector);
        guard.setAlternates(id, _alts(CL100));
        vm.stopPrank();
    }

    function test_setAlternates_atMostThree() public {
        uint256 id = _open();
        address[] memory four = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            four[i] = CL50;
        }
        vm.prank(user);
        vm.expectRevert(GuardCore.TooManyAlternates.selector);
        guard.setAlternates(id, four);
    }

    function test_close_forgetsAlternates() public {
        uint256 id = _open();
        vm.startPrank(user);
        guard.setAlternates(id, _alts(CL50));
        guard.close(id);
        vm.stopPrank();
        assertEq(guard.alternatesOf(id).length, 0);
    }

    // ---- measuring pay ----

    function test_payRate_zeroUntilAFullWindowHasPassed() public {
        _open(); // takes the first reading of CL100
        (, uint64 readAt,,) = guard.meter().payMark(CL100);
        assertEq(readAt, vm.getBlockTimestamp());
        assertEq(guard.meter().payRate(CL100, 500), 0);
        assertEq(guard.meter().payRate(CL50, 500), 0); // never read
    }

    /// The pool's reward counter after a day is set by hand: on a fork nobody runs the gauge.
    function test_payRate_followsTheCounter_andRanksPools() public {
        uint256 id = _open();
        vm.prank(user);
        guard.setAlternates(id, _alts(CL50));
        vm.prank(user);
        guard.review(id); // first reading of CL50 (CL100 was read at open, too fresh to read again)
        (, uint64 at50,,) = guard.meter().payMark(CL50);
        assertGt(at50, 0);

        // The guard's own readings (counter plus what had accrued unsettled at that moment).
        (uint256 g100,,,) = guard.meter().payMark(CL100);
        (uint256 g50,,,) = guard.meter().payMark(CL50);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // Only the mocked counters move: no real emissions accrued over the warp.
        _unsettled(CL100, 0);
        _unsettled(CL50, 0);
        // Both pools paid the same per unit of liquidity...
        uint256 grown = 1e30;
        vm.mockCall(CL100, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g100 + grown));
        vm.mockCall(CL50, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g50 + grown));

        uint256 r100 = guard.meter().payRate(CL100, 500);
        uint256 r50 = guard.meter().payRate(CL50, 500);
        console2.log("pay per second, step 100:", r100);
        console2.log("pay per second, step 50: ", r50);
        assertGt(r100, 0);
        assertGt(r50, 0);
        // ...and the same range width means the same liquidity per dollar, so the same pay.
        assertApproxEqRel(r100, r50, 0.05e18);

        // A narrower range holds more liquidity per dollar, so it earns more of the same counter.
        assertGt(guard.meter().payRate(CL100, 200), r100);

        // Twice the counter growth in step 50: it pays twice as much.
        vm.mockCall(CL50, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g50 + 2 * grown));
        assertApproxEqRel(guard.meter().payRate(CL50, 500), 2 * r50, 0.01e18);
    }

    /// Codex 15.11 (1): a quiet pool's counter only moves when the pool is touched. The AERO accrued
    /// since its last settlement counts too, exactly as if the counter had already moved.
    function test_payRate_countsUnsettledAero_ofAQuietPool() public {
        _open();
        uint256 g = ICLPool(CL100).rewardGrowthGlobalX128();
        uint256 staked = ICLPool(CL100).stakedLiquidity();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 aero = 50e18;

        // Untouched pool: counter frozen, 50 AERO waiting in the voter.
        vm.mockCall(CL100, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g));
        _unsettled(CL100, aero);
        uint256 quiet = guard.meter().payRate(CL100, 500);
        assertGt(quiet, 0);

        // The same 50 AERO already settled into the counter: the same pay.
        vm.mockCall(
            CL100, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g + aero * 2 ** 128 / staked)
        );
        _unsettled(CL100, 0);
        assertApproxEqRel(guard.meter().payRate(CL100, 500), quiet, 0.001e18);
    }

    /// Codex 15.11 (2): an alternate pool too young for a 30-minute average (observe reverts "OLD")
    /// must not undo the review of the position itself.
    function test_review_alternateWithoutHistory_doesNotBlockTheReview() public {
        uint256 id = _open();
        vm.prank(user);
        guard.setAlternates(id, _alts(CL50));
        uint256 before = guard.meter().snapsOf(CL100).length;
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.mockCallRevert(CL50, abi.encodeWithSelector(ICLPool.observe.selector), "OLD");
        vm.prank(user);
        guard.review(id); // must not revert
        assertEq(guard.meter().snapsOf(CL100).length, before + 1); // the position's own pool was still read
        assertEq(guard.meter().snapsOf(CL50).length, 0); // the young alternate simply skipped
    }

    /// Codex 16.11: a mark taken with unsettled AERO, then a voter that can't be read, must not
    /// read as a wrapped counter (an enormous pay); the next mark never moves back either.
    function test_payRate_voterFailsAfterMark_noWrap() public {
        // The position's own pool is settled by the review's claim; an alternate is only read, so its
        // mark can include AERO still waiting unsettled.
        uint256 id = _open();
        vm.prank(user);
        guard.setAlternates(id, _alts(CL50));
        vm.warp(vm.getBlockTimestamp() + 13 hours);
        uint256 frozen = ICLPool(CL50).rewardGrowthGlobalX128();
        vm.mockCall(CL50, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(frozen));
        vm.mockCall(CL50, abi.encodeWithSignature("lastUpdated()"), abi.encode(uint48(vm.getBlockTimestamp() - 1)));
        _unsettled(CL50, 1_000e18);
        vm.prank(user);
        guard.review(id);
        (uint256 g0, uint64 at0,,) = guard.meter().payMark(CL50);
        assertEq(at0, vm.getBlockTimestamp());
        assertGt(g0, frozen); // the mark counted the waiting AERO
        // The pool stays untouched and the voter stops answering.
        address gauge = ICLPool(CL50).gauge();
        vm.mockCallRevert(
            ICLGauge(gauge).voter(), abi.encodeCall(ILeafVoter.projectedCumulativeRewardShare, (gauge)), "down"
        );
        vm.warp(vm.getBlockTimestamp() + 13 hours);
        vm.mockCall(CL50, abi.encodeWithSignature("lastUpdated()"), abi.encode(uint48(vm.getBlockTimestamp() - 1)));
        assertEq(guard.meter().payRate(CL50, 500), 0); // read as no pay measured, not as a wrap
        vm.prank(user);
        guard.review(id); // the next mark is not taken while the voter can't be read (Codex 26.11)
        (uint256 g1, uint64 at1,,) = guard.meter().payMark(CL50);
        assertEq(at1, at0, "no mark from a reading without its unsettled part");
        assertEq(g1, g0); // never moved back
    }

    /// Codex 16.11 (4): a 30-minute average past the last usable tick of the step (887250 > 887200
    /// for step 100) values the range as one token instead of underflowing.
    function test_payRate_priceBeyondTheLastUsableTick_doesNotRevert() public {
        _open();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        int56[] memory cum = new int56[](2);
        cum[0] = 0;
        cum[1] = int56(887_250) * int56(uint56(guard.TWAP_WINDOW()));
        uint160[] memory spl = new uint160[](2);
        vm.mockCall(CL100, abi.encodeWithSelector(ICLPool.observe.selector), abi.encode(cum, spl));
        uint256 g = ICLPool(CL100).rewardGrowthGlobalX128();
        vm.mockCall(CL100, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g + 1e30));
        guard.meter().payRate(CL100, 500); // must not revert
        guard.meter().payRate(CL100, 500_000);
    }

    /// If the voter can't be read, no pay is measured (never a partial counter), and nothing reverts.
    function test_payRate_voterReverts_readsAsNoPay() public {
        _open();
        address gauge = ICLPool(CL100).gauge();
        address voter = ICLGauge(gauge).voter();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.mockCallRevert(voter, abi.encodeCall(ILeafVoter.projectedCumulativeRewardShare, (gauge)), "down");
        uint256 g = ICLPool(CL100).rewardGrowthGlobalX128();
        vm.mockCall(CL100, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g + 1e30));
        vm.mockCall(CL100, abi.encodeWithSignature("lastUpdated()"), abi.encode(uint48(vm.getBlockTimestamp() - 1)));
        assertEq(guard.meter().payRate(CL100, 500), 0);
    }

    /// A reading is taken at most once per window, so many reviews in a row cannot shrink it.
    function test_markPay_atMostOncePerWindow_keepsThePreviousReading() public {
        uint256 id = _open();
        (uint256 g0, uint64 t0,,) = guard.meter().payMark(CL100);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(user);
        guard.review(id);
        (, uint64 t1,,) = guard.meter().payMark(CL100);
        assertEq(t1, t0); // too soon: no new reading

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        vm.prank(user);
        guard.review(id);
        (, uint64 t2, uint256 prevG, uint64 prevT) = guard.meter().payMark(CL100);
        assertEq(t2, vm.getBlockTimestamp());
        assertEq(prevT, t0);
        assertEq(prevG, g0);
        // Right after the new reading the rate is measured from the previous one, not from zero time.
        uint256 g = ICLPool(CL100).rewardGrowthGlobalX128();
        vm.mockCall(CL100, abi.encodeWithSignature("rewardGrowthGlobalX128()"), abi.encode(g + 1e30));
        assertGt(guard.meter().payRate(CL100, 500), 0);
    }
}
