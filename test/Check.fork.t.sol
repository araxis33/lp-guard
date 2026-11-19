// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {PoolMath} from "../src/lib/PoolMath.sol";
import {INonfungiblePositionManager, IERC20} from "../src/interfaces/IAero.sol";
import {Swapper} from "./Review.fork.t.sol";

interface IERC20Approve2 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// The hourly check on a fork of Base mainnet: snapshots for the net rule, and the close after a
/// position's price has stayed out of range for its grace period.
contract CheckForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // AERO/WETH CL200
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;

    PositionGuard guard;
    address user = makeAddr("user");
    address proxy = makeAddr("callbackProxy");
    address reactive = makeAddr("reactiveContract");
    uint256 clock;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = new PositionGuard(NPM, AERO, proxy, reactive, SUGAR);
        clock = vm.getBlockTimestamp();
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _open(uint16 halfWidth, uint32 grace) internal returns (uint256 id) {
        deal(AERO, user, 1_000e18);
        deal(WETH, user, 1e18);
        vm.startPrank(user);
        IERC20Approve2(AERO).approve(address(guard), type(uint256).max);
        IERC20Approve2(WETH).approve(address(guard), type(uint256).max);
        id = guard.open(
            PositionGuard.OpenParams({
                pool: POOL,
                amount0: 1_000e18,
                amount1: 1e18,
                halfWidth: halfWidth,
                amount0Min: 0,
                amount1Min: 0,
                stake: true,
                graceSeconds: grace,
                maxLossBps: 0
            })
        );
        vm.stopPrank();
    }

    function _push(bool wethIn, uint256 amount) internal {
        Swapper s = new Swapper();
        deal(wethIn ? WETH : AERO, address(s), amount);
        s.swap(POOL, !wethIn, amount); // token0 = AERO, token1 = WETH
    }

    function _check() internal {
        vm.prank(proxy);
        guard.checkByReactive(reactive);
    }

    function test_check_onlyFromTheProxy_andTheReactiveContract() public {
        _open(5, 3 hours);
        vm.expectRevert();
        guard.checkByReactive(reactive);
        vm.prank(proxy);
        vm.expectRevert();
        guard.checkByReactive(makeAddr("stranger"));
    }

    function test_check_keepsAnHourlySnapshot_soSwingsAreMeasuredWithinHours() public {
        _open(5, 3 hours);
        assertEq(guard.snapsOf(POOL).length, 1, "a snapshot is kept at the deposit");
        _check();
        assertEq(guard.snapsOf(POOL).length, 1, "not twice within the hour");
        _push(true, 20e18);
        _skip(1 hours);
        _check();
        _push(false, 20_000e18);
        _skip(1 hours);
        uint256 g0 = gasleft();
        _check();
        console2.log("gas for the hourly check of one position:", g0 - gasleft());
        PoolMath.Snap[] memory s = guard.snapsOf(POOL);
        assertEq(s.length, 3, "three snapshots two hours after the deposit");
        assertGt(guard.priceVariance(POOL), 0, "swings measured on the same day, not after three days");
    }

    function test_check_closesAfterTheGracePeriodOutOfRange_andSendsAllToTheOwner() public {
        uint256 id = _open(1, 3 hours);
        _push(true, 400e18);
        _skip(31 minutes); // the 30-minute average now sits at the new price
        _check();
        (uint32 grace, uint64 outSince) = guard.rangeWatch(id);
        assertEq(grace, 3 hours);
        assertEq(outSince, uint64(clock), "out of range noted");
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "kept while the grace period runs");

        _skip(2 hours);
        _check();
        (owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "still inside the grace period");

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 aeroBefore = IERC20(AERO).balanceOf(user);
        _skip(1 hours);
        _check();
        (owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "closed after three hours out");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user, "empty NFT back");
        assertTrue(
            IERC20(WETH).balanceOf(user) > wethBefore || IERC20(AERO).balanceOf(user) > aeroBefore,
            "coins back to the owner"
        );
        assertEq(guard.reviewCount(), 0, "off the lists");
    }

    function test_check_priceComingBack_resetsTheClock() public {
        uint256 id = _open(1, 3 hours);
        _push(true, 400e18);
        _skip(31 minutes);
        _check();
        (, uint64 outSince) = guard.rangeWatch(id);
        assertGt(outSince, 0, "out");

        _push(false, 400_000e18); // AERO sold back in: the price returns
        _skip(31 minutes);
        _check();
        (, outSince) = guard.rangeWatch(id);
        (, int24 avg) = (0, PoolMath.twapTick(POOL));
        (,,,,, int24 lower, int24 upper,,,,,) = INonfungiblePositionManager(NPM).positions(id);
        if (avg >= lower && avg < upper) {
            assertEq(outSince, 0, "back inside: the clock starts over");
        } else {
            console2.log("push back missed the range; avg tick:", int256(avg));
        }
    }

    function test_check_withoutGrace_neverCloses() public {
        uint256 id = _open(1, 0);
        _push(true, 400e18);
        _skip(31 minutes);
        _check();
        _skip(5 hours);
        _check();
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "grace 0: the hourly check only takes snapshots");
    }
}
