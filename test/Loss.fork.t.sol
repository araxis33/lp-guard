// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PoolMath} from "../src/lib/PoolMath.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {Swapper} from "./Review.fork.t.sol";

/// Price snapshots and the expected loss to price swings, on a fork of Base: the real AERO/WETH pool.
contract LossForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // AERO/WETH CL200
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;

    PositionGuard guard;
    uint256 t; // our own clock: block.timestamp after vm.warp can be stale under via-IR

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = new PositionGuard(NPM, AERO, makeAddr("proxy"), makeAddr("reactive"), SUGAR);
        t = vm.getBlockTimestamp();
    }

    function _tick() internal view returns (int24 tick) {
        (bool ok, bytes memory ret) = POOL.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok, "slot0");
        (, tick) = abi.decode(ret, (uint160, int24));
    }

    /// Sell `wethIn` into the pool (price up), or `aeroIn` (price down).
    function _swing(uint256 wethIn, uint256 aeroIn) internal {
        Swapper s = new Swapper();
        if (wethIn > 0) {
            deal(WETH, address(s), wethIn);
            s.swap(POOL, false, wethIn);
        } else {
            deal(AERO, address(s), aeroIn);
            s.swap(POOL, true, aeroIn);
        }
    }

    function _hourLater() internal {
        t += 1 hours + 1;
        vm.warp(t);
        vm.roll(block.number + 1);
    }

    /// Four hourly snapshots while the price is pushed up and down by `wethIn`.
    function _swingFourHours(uint256 wethIn) internal returns (uint256 loss) {
        guard.snap(POOL);
        for (uint256 i = 0; i < 3; i++) {
            int24 before = _tick();
            if (i % 2 == 0) _swing(wethIn, 0);
            else _swing(0, wethIn * 1_000); // roughly the same value back in AERO
            console2.log("ticks moved:", int256(_tick()) - int256(before));
            _hourLater();
            guard.snap(POOL);
        }
        loss = guard.lossRate(POOL, 1000);
    }

    function test_snap_keepsAtMostOnePerHour() public {
        guard.snap(POOL);
        guard.snap(POOL); // same hour: ignored
        assertEq(guard.snapsOf(POOL).length, 1);
        t += 30 minutes;
        vm.warp(t);
        guard.snap(POOL);
        assertEq(guard.snapsOf(POOL).length, 1);
        _hourLater();
        guard.snap(POOL);
        assertEq(guard.snapsOf(POOL).length, 2);
    }

    function test_snap_onlyRealPools() public {
        vm.expectRevert();
        guard.snap(makeAddr("notAPool"));
    }

    function test_lossRate_zeroUntilThreeSnapshots() public {
        guard.snap(POOL);
        _hourLater();
        guard.snap(POOL);
        assertEq(guard.lossRate(POOL, 1000), 0);
        assertEq(guard.priceVariance(POOL), 0);
    }

    function test_snap_ringKeepsTheLast24() public {
        for (uint256 i = 0; i < 30; i++) {
            guard.snap(POOL);
            _hourLater();
        }
        PoolMath.Snap[] memory s = guard.snapsOf(POOL);
        assertEq(s.length, 24);
        for (uint256 i = 1; i < s.length; i++) {
            assertGt(s[i].at, s[i - 1].at); // oldest first, no gaps
        }
    }

    function test_lossRate_growsWithBiggerSwings() public {
        uint256 snapshot = vm.snapshotState();
        uint256 small = _swingFourHours(20e18);
        vm.revertToState(snapshot);
        t = vm.getBlockTimestamp();
        uint256 big = _swingFourHours(200e18);

        console2.log("loss per day, small swings (bps):", small * 1 days / 1e14);
        console2.log("loss per day, big swings (bps):", big * 1 days / 1e14);
        assertGt(small, 0);
        assertGt(big, small * 4); // variance grows with the square of the move
        // A narrower range loses more of its value to the same swings.
        assertGt(guard.lossRate(POOL, 400), big);
    }
}
