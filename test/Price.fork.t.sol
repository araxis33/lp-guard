// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";

/// Pricing AERO in a pool's token1, on a fork of Base: directly in an AERO pool, and through
/// AERO/WETH for the WETH/USDC pool, which has no AERO in it.
contract PriceForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;
    address constant AERO_WETH = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // AERO token0, WETH token1
    address constant WETH_USDC = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH token0, USDC token1
    address constant WETH_USDC_100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24; // same pair, no AERO

    PositionGuard guard;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = new PositionGuard(NPM, AERO, makeAddr("proxy"), makeAddr("reactive"), SUGAR);
    }

    function test_aeroPrice_inAnAeroPool() public view {
        uint256 inWeth = guard.aeroPrice(AERO_WETH, address(0));
        console2.log("1 AERO in WETH wei:", inWeth);
        assertGt(inWeth, 0);
    }

    function test_aeroPrice_throughAnotherPool_matchesTheTwoPrices() public view {
        uint256 inUsdc = guard.aeroPrice(WETH_USDC, AERO_WETH); // USDC has 6 decimals
        console2.log("1 AERO in USDC (6 dec):", inUsdc);
        assertGt(inUsdc, 0.2e6);
        assertLt(inUsdc, 1.5e6);
        // the same as AERO -> WETH, then WETH -> USDC at the WETH/USDC pool's price
        uint256 inWeth = guard.aeroPrice(AERO_WETH, address(0));
        uint256 wethInUsdc = guard.aeroPrice(WETH_USDC, address(0)) == 0 ? _wethInUsdc() : 0;
        assertApproxEqRel(inUsdc, inWeth * wethInUsdc / 1e18, 0.001e18);
    }

    function test_aeroPrice_zeroWithoutARoute() public view {
        assertEq(guard.aeroPrice(WETH_USDC, address(0)), 0);
    }

    function test_aeroPrice_rejectsAPoolWithoutAero() public {
        vm.expectRevert(PositionGuard.BadPricePool.selector);
        guard.aeroPrice(WETH_USDC, WETH_USDC_100);
    }

    function test_setPricePool_ownerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.setPricePool(1, AERO_WETH);
    }

    function test_netRate_zeroBeforeAnyReadings() public view {
        assertEq(guard.netRate(WETH_USDC, 1000, AERO_WETH), 0);
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
}
