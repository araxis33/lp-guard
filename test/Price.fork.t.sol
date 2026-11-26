// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {IGuard, GuardDeploy} from "./GuardAll.sol";
import {GuardCore} from "../src/GuardCore.sol";
import {GuardMeter} from "../src/GuardMeter.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

interface IERC20Approve {
    function approve(address, uint256) external returns (bool);
}

/// Pricing AERO in a pool's token1, on a fork of Base: directly in an AERO pool, and through
/// AERO/WETH for the WETH/USDC pool, which has no AERO in it.
contract PriceForkTest is Test {
    using stdStorage for StdStorage;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address user = makeAddr("user");
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;
    address constant AERO_WETH = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // AERO token0, WETH token1
    address constant WETH_USDC = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH token0, USDC token1
    address constant WETH_USDC_100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24; // same pair, no AERO

    IGuard guard;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = GuardDeploy.deploy(NPM, AERO, makeAddr("proxy"), makeAddr("reactive"), SUGAR);
    }

    function test_aeroPrice_inAnAeroPool() public view {
        uint256 inWeth = guard.meter().aeroPrice(AERO_WETH, address(0));
        console2.log("1 AERO in WETH wei:", inWeth);
        assertGt(inWeth, 0);
    }

    function test_aeroPrice_throughAnotherPool_matchesTheTwoPrices() public view {
        uint256 inUsdc = guard.meter().aeroPrice(WETH_USDC, AERO_WETH); // USDC has 6 decimals
        console2.log("1 AERO in USDC (6 dec):", inUsdc);
        assertGt(inUsdc, 0.2e6);
        assertLt(inUsdc, 1.5e6);
        // the same as AERO -> WETH, then WETH -> USDC at the WETH/USDC pool's price
        uint256 inWeth = guard.meter().aeroPrice(AERO_WETH, address(0));
        uint256 wethInUsdc = guard.meter().aeroPrice(WETH_USDC, address(0)) == 0 ? _wethInUsdc() : 0;
        assertApproxEqRel(inUsdc, inWeth * wethInUsdc / 1e18, 0.001e18);
    }

    function test_aeroPrice_zeroWithoutARoute() public view {
        assertEq(guard.meter().aeroPrice(WETH_USDC, address(0)), 0);
    }

    function test_aeroPrice_rejectsAPoolWithoutAero() public {
        GuardMeter m = guard.meter();
        vm.expectRevert(GuardCore.BadPricePool.selector);
        m.aeroPrice(WETH_USDC, WETH_USDC_100);
    }

    function test_setPricePool_ownerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(GuardCore.NotOwner.selector);
        guard.setPricePool(1, AERO_WETH);
    }

    function test_netRate_zeroBeforeAnyReadings() public view {
        assertEq(guard.meter().netRate(WETH_USDC, 1000, AERO_WETH), 0);
    }

    /// 1e18 WETH in USDC at the WETH/USDC pool's 30-minute average, read the same way the guard does.
    function _wethInUsdc() internal view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = 30 minutes;
        (bool ok, bytes memory ret) = WETH_USDC.staticcall(abi.encodeWithSignature("observe(uint32[])", ago));
        require(ok, "observe");
        (int56[] memory cum,) = abi.decode(ret, (int56[], uint160[]));
        int56 d = cum[1] - cum[0];
        int24 tick = int24(d / 1800);
        if (d < 0 && d % 1800 != 0) tick--;
        (ok, ret) = SUGAR.staticcall(abi.encodeWithSignature("getSqrtRatioAtTick(int24)", tick));
        require(ok, "sqrt");
        uint256 sqrtP = abi.decode(ret, (uint160));
        return uint256(1e18) * sqrtP / 2 ** 96 * sqrtP / 2 ** 96;
    }

    /// A WETH/USDC position that has been paid 100 AERO: the review sees their worth only once
    /// the owner names a price pool (before, AERO in a pool without AERO counted as zero).
    function test_standing_pricesAeroPaidThroughThePricePool() public {
        uint256 id = _openWethUsdc();
        uint256 slot = stdstore.target(address(guard)).sig("guarded(uint256)").with_key(id).depth(0).find();
        vm.store(address(guard), bytes32(uint256(slot) + 4), bytes32(uint256(100e18))); // aeroPaid
        (,, uint256 before) = guard.standing(id);
        assertEq(before, 0);
        vm.prank(user);
        guard.setPricePool(id, AERO_WETH);
        (,, uint256 aeroValue) = guard.standing(id);
        console2.log("100 AERO paid, in USDC (6 dec):", aeroValue);
        assertApproxEqRel(aeroValue, 100 * guard.meter().aeroPrice(WETH_USDC, AERO_WETH), 0.0001e18);
        assertGt(aeroValue, 20e6);
    }

    function _openWethUsdc() internal returns (uint256 id) {
        deal(WETH, user, 1e18);
        deal(USDC, user, 5_000e6);
        vm.startPrank(user);
        IERC20Approve(WETH).approve(address(guard), type(uint256).max);
        IERC20Approve(USDC).approve(address(guard), type(uint256).max);
        id = guard.open(
            GuardCore.OpenParams({
                pool: WETH_USDC,
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
}
