// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {INonfungiblePositionManager, ICLPool, IERC20} from "../src/interfaces/IAero.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// The daily review on a fork of Base mainnet: a real AERO/WETH Slipstream pool and its gauge.
contract ReviewForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // AERO/WETH CL200
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5; // Aero SugarHelper

    PositionGuard guard;
    address user = makeAddr("user");
    address proxy = makeAddr("callbackProxy");
    address reactive = makeAddr("reactiveContract");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = new PositionGuard(NPM, AERO, proxy, reactive, SUGAR);
    }

    function _slot0() internal view returns (uint160 sqrtP, int24 tick) {
        (bool ok, bytes memory ret) = POOL.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok, "slot0");
        (sqrtP, tick) = abi.decode(ret, (uint160, int24));
    }

    function _openParams(uint256 a0, uint256 a1) internal pure returns (PositionGuard.OpenParams memory) {
        return PositionGuard.OpenParams({
            pool: POOL,
            amount0: a0,
            amount1: a1,
            halfWidth: 5,
            amount0Min: 0,
            amount1Min: 0,
            stake: true,
            graceSeconds: 3 hours,
            maxLossBps: 0
        });
    }
    // ---- daily review: position against simply holding ----

    uint256 constant PUSH = 400e18; // WETH sold into the pool to move the price

    function _openWithLimit(uint16 maxLossBps) internal returns (uint256 id) {
        deal(AERO, user, 1_000e18);
        deal(WETH, user, 1e18);
        PositionGuard.OpenParams memory p = _openParams(1_000e18, 1e18);
        p.maxLossBps = maxLossBps;
        vm.startPrank(user);
        IERC20Approve(AERO).approve(address(guard), type(uint256).max);
        IERC20Approve(WETH).approve(address(guard), type(uint256).max);
        id = guard.open(p);
        vm.stopPrank();
    }

    /// Someone sells a lot of WETH into the pool: AERO gets dearer, the position drifts from holding.
    function _pushPrice(uint256 wethIn) internal {
        (, int24 before) = _slot0();
        Swapper s = new Swapper();
        deal(WETH, address(s), wethIn);
        s.swap(POOL, false, wethIn); // token1 (WETH) in
        (, int24 afterTick) = _slot0();
        console2.log("price pushed by ticks:", uint256(int256(afterTick - before)));
    }

    /// On a fork nobody runs the gauge's epoch distribution, so no new AERO accrues here; this
    /// checks the bookkeeping: whatever the claim pays the owner is what the guard remembers.
    function test_review_keepsAHealthyPosition_andRemembersAeroPaid() public {
        uint256 id = _openWithLimit(500); // close only if 5% behind holding
        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 aeroBefore = IERC20(AERO).balanceOf(user);
        vm.prank(user);
        guard.review(id);
        uint256 got = IERC20(AERO).balanceOf(user) - aeroBefore;
        console2.log("AERO paid to owner by the review:", got);

        (address owner,,,,,, uint256 aeroPaid) = guard.guarded(id);
        assertEq(owner, user, "still guarded");
        assertEq(aeroPaid, got, "AERO paid is remembered exactly");

        (uint256 hold, uint256 pos,) = guard.standing(id);
        console2.log("hold / position, in WETH wei:", hold, pos);
        assertApproxEqRel(pos, hold, 0.001e18, "price did not move: position is worth what holding is");
    }

    function test_review_closesAPositionThatFellBehindHolding() public {
        uint256 id = _openWithLimit(20); // 0.2%
        _pushPrice(PUSH);
        vm.warp(vm.getBlockTimestamp() + 31 minutes); // the 30-minute average now sits at the new price

        (uint256 hold, uint256 pos, uint256 aeroV) = guard.standing(id);
        console2.log("after the move - hold / position / AERO:", hold, pos, aeroV);
        assertLt(pos, hold, "the move left the position behind holding");

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "closed");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user, "empty NFT back");
        assertGt(IERC20(WETH).balanceOf(user), wethBefore, "tokens back to the owner");
        assertEq(guard.reviewCount(), 0, "off the review list");
    }

    function test_review_withoutLimit_onlyReports() public {
        uint256 id = _openWithLimit(0);
        _pushPrice(PUSH);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "no limit set: the review never closes");
    }

    function test_reviewByReactive_goesThroughEveryPosition_andOnlyFromTheProxy() public {
        uint256 a = _openWithLimit(20);
        uint256 b = _openWithLimit(0);
        assertEq(guard.reviewCount(), 2);
        _pushPrice(PUSH);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);

        vm.prank(stranger);
        vm.expectRevert();
        guard.reviewByReactive(reactive);
        vm.prank(proxy);
        vm.expectRevert();
        guard.reviewByReactive(stranger);

        uint256 g0 = gasleft();
        vm.prank(proxy);
        guard.reviewByReactive(reactive);
        console2.log("gas for a review of two positions (one closed):", g0 - gasleft());
        (address ownerA,,,,,,) = guard.guarded(a);
        (address ownerB,,,,,,) = guard.guarded(b);
        assertEq(ownerA, address(0), "a had a limit and fell behind: closed");
        assertEq(ownerB, user, "b has no limit: kept");
        assertEq(guard.reviewCount(), 1);
    }

    function test_review_waitsWhileThePriceIsBeingPushed() public {
        uint256 id = _openWithLimit(20);
        _pushPrice(PUSH);
        vm.warp(vm.getBlockTimestamp() + 31 minutes); // behind holding at the average price
        _pushPrice(PUSH); // someone shoves the price right before the review
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "spot far from the average: the close waits");

        vm.warp(vm.getBlockTimestamp() + 31 minutes); // the price stayed there: the average caught up
        vm.prank(user);
        guard.review(id);
        (owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "then it closes");
    }

    function test_reviewByReactive_everyPositionGetsItsTurn() public {
        uint256 total = 4; // more than one run's worth (MAX_REVIEW = 2)
        for (uint256 i = 0; i < total; i++) {
            _openWithLimit(0);
        }
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bytes32 reviewed = keccak256("Reviewed(uint256,uint256,uint256,uint256,bool)");
        vm.recordLogs();
        vm.prank(proxy);
        guard.reviewByReactive(reactive);
        vm.prank(proxy);
        guard.reviewByReactive(reactive);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        uint256[] memory ids = new uint256[](logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(guard) || logs[i].topics[0] != reviewed) continue;
            uint256 id = uint256(logs[i].topics[1]);
            bool dup;
            for (uint256 j = 0; j < count; j++) {
                if (ids[j] == id) dup = true;
            }
            if (!dup) ids[count++] = id;
        }
        assertEq(count, total, "two daily runs reach all four positions");
    }

    function test_setMaxLoss_ownerOnly_andBounded() public {
        uint256 id = _openWithLimit(0);
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.setMaxLoss(id, 100);
        vm.prank(user);
        vm.expectRevert(PositionGuard.BadLimit.selector);
        guard.setMaxLoss(id, 10_000);
        vm.prank(user);
        guard.setMaxLoss(id, 100);
        (,,, uint16 limit,,,) = guard.guarded(id);
        assertEq(limit, 100);
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.review(id);
    }

    // ---- exit when the pool no longer pays for its swings (netExitBps) ----

    /// The price swings hard every hour for five hours (a snapshot after each swing), then the
    /// pay window fills up: the guard has measured pay, swings and the AERO price.
    function _swingForHours() internal {
        Swapper s = new Swapper();
        for (uint256 i = 0; i < 5; i++) {
            if (i % 2 == 0) {
                deal(WETH, address(s), PUSH);
                s.swap(POOL, false, PUSH); // WETH in: AERO dearer
            } else {
                s.swap(POOL, true, IERC20(AERO).balanceOf(address(s))); // the AERO back: price returns
            }
            vm.warp(vm.getBlockTimestamp() + 61 minutes); // the 30-minute average follows
            guard.snap(POOL);
        }
        vm.warp(vm.getBlockTimestamp() + 8 hours); // past the 12 h pay window since the open
    }

    function test_netExit_closesWhenSwingsCostMoreThanThePoolPays() public {
        uint256 id = _openWithLimit(0); // no "behind holding" limit: only the net rule can close it
        vm.prank(user);
        guard.setNetExit(id, 1); // leave when it loses more than 0.01% a day net
        _swingForHours();

        (int256 net, bool measured) = guard.netPerDay(id);
        console2.log("net per day, 1e18 = 100%:", net);
        assertTrue(measured, "pay, swings and AERO price are all measured");
        assertLt(net, 0, "hourly swings of hundreds of ticks cost more than the AERO paid");

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        vm.expectEmit(true, false, false, false, address(guard));
        emit PositionGuard.NetExitDue(id, 0);
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "closed by the net rule");
        assertGt(IERC20(WETH).balanceOf(user), wethBefore, "tokens back to the owner");
        assertEq(guard.netExitBps(id), 0, "the rule is cleared with the position");
    }

    function test_netExit_fitsTheDailyRunByReactive() public {
        uint256 id = _openWithLimit(0);
        vm.prank(user);
        guard.setNetExit(id, 1);
        _swingForHours();
        vm.prank(proxy);
        guard.reviewByReactive(reactive); // each position gets GAS_PER_REVIEW; a failure would be swallowed
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "the daily run closes it within its gas");
    }

    function test_netExit_deferredClose_saysNothing() public {
        uint256 id = _openWithLimit(0);
        vm.prank(user);
        guard.setNetExit(id, 1);
        _swingForHours();
        _pushPrice(PUSH); // spot shoved away from the 30-minute average right before the review
        vm.recordLogs();
        vm.prank(user);
        guard.review(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 due = keccak256("NetExitDue(uint256,int256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != due, "no exit announced while it waits");
        }
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "the close waits for a calm price");
    }

    function test_netExit_unstakedPosition_isNeverMeasured_andReviewWorks() public {
        deal(AERO, user, 1_000e18);
        deal(WETH, user, 1e18);
        PositionGuard.OpenParams memory p = _openParams(1_000e18, 1e18);
        p.stake = false; // earns fees, not AERO
        vm.startPrank(user);
        IERC20Approve(AERO).approve(address(guard), type(uint256).max);
        IERC20Approve(WETH).approve(address(guard), type(uint256).max);
        uint256 id = guard.open(p);
        guard.setNetExit(id, 1);
        vm.stopPrank();
        _swingForHours();
        (, bool measured) = guard.netPerDay(id);
        assertFalse(measured, "no AERO pay to weigh: not measured");
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "kept, and the review did not revert");
    }

    function test_netExit_off_keepsThePosition() public {
        uint256 id = _openWithLimit(0);
        _swingForHours();
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "rule off: the same swings do not close it");
    }

    function test_netExit_waitsUntilEverythingIsMeasured() public {
        uint256 id = _openWithLimit(0);
        vm.prank(user);
        guard.setNetExit(id, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (, bool measured) = guard.netPerDay(id);
        assertFalse(measured, "no full pay window and no swings yet");
        vm.prank(user);
        guard.review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "an unmeasured reading never closes");
    }

    function test_setNetExit_ownerOnly_andBounded() public {
        uint256 id = _openWithLimit(0);
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.setNetExit(id, 10);
        vm.prank(user);
        vm.expectRevert(PositionGuard.BadLimit.selector);
        guard.setNetExit(id, 10_000);
        vm.prank(user);
        guard.setNetExit(id, 10);
        assertEq(guard.netExitBps(id), 10);
    }
}

/// Swaps in a pool directly, paying in the callback.
contract Swapper {
    function swap(address pool, bool zeroForOne, uint256 amountIn) external {
        ICLPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                ""
            );
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        address token = a0 > 0 ? ICLPool(msg.sender).token0() : ICLPool(msg.sender).token1();
        IERC20(token).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }
}
