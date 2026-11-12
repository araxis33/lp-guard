// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {INonfungiblePositionManager, ICLFactory, ICLPool, IERC20} from "../src/interfaces/IAero.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// Runs against a fork of Base mainnet: a real AERO/WETH Slipstream pool, its real gauge.
contract PositionGuardForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee; // AERO after the merger (pool token0, $0.56)
    address constant OLD_AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631; // pre-merger AERO, same symbol
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant POOL = 0xc85D5CB72d1aaD6f152A8decAd228AE4A59Ac9B3; // AERO/WETH CL200
    int24 constant SPACING = 200;

    PositionGuard guard;
    address user = makeAddr("user");
    address proxy = makeAddr("callbackProxy");
    address reactive = makeAddr("reactiveContract");
    address stranger = makeAddr("stranger");
    uint256 tokenId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = new PositionGuard(NPM, AERO, proxy, reactive);

        deal(AERO, user, 2_000e18);
        deal(WETH, user, 1e18);

        (uint160 sqrtP, int24 tick) = _slot0();
        sqrtP;
        int24 mid = (tick / SPACING) * SPACING;
        vm.startPrank(user);
        IERC20Approve(AERO).approve(NPM, type(uint256).max);
        IERC20Approve(WETH).approve(NPM, type(uint256).max);
        (tokenId,,,) = INonfungiblePositionManager(NPM)
            .mint(
                INonfungiblePositionManager.MintParams({
                    token0: AERO,
                    token1: WETH,
                    tickSpacing: SPACING,
                    tickLower: mid - 5 * SPACING,
                    tickUpper: mid + 5 * SPACING,
                    amount0Desired: 1_000e18,
                    amount1Desired: 0.3e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: user,
                    deadline: block.timestamp,
                    sqrtPriceX96: 0
                })
            );
        INonfungiblePositionManager(NPM).approve(address(guard), tokenId);
        vm.stopPrank();
    }

    function _slot0() internal view returns (uint160 sqrtP, int24 tick) {
        (bool ok, bytes memory ret) = POOL.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok, "slot0");
        (sqrtP, tick) = abi.decode(ret, (uint160, int24));
    }

    function test_gaugeResolvesFromPosition() public view {
        assertEq(guard.gaugeOf(tokenId), ICLPool(POOL).gauge());
    }

    function test_depositStakes_thenReactiveCloses_everythingGoesToOwner() public {
        vm.prank(user);
        guard.deposit(tokenId, true, 3 hours);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(tokenId), guard.gaugeOf(tokenId), "NFT sits in the gauge");

        vm.warp(block.timestamp + 1 days);
        uint256 pending = guard.pendingAero(tokenId);
        console2.log("pending AERO after 1 day (wei):", pending);

        uint256 a0 = IERC20(AERO).balanceOf(user);
        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 o0 = IERC20(OLD_AERO).balanceOf(user);
        vm.prank(proxy);
        guard.closeByReactive(reactive, tokenId);
        console2.log("AERO (new) to owner:", IERC20(AERO).balanceOf(user) - a0);
        console2.log("AERO (old) to owner:", IERC20(OLD_AERO).balanceOf(user) - o0);
        console2.log("WETH to owner:", IERC20(WETH).balanceOf(user) - w0);

        assertGt(IERC20(AERO).balanceOf(user), a0, "owner got AERO back");
        assertGt(IERC20(WETH).balanceOf(user), w0, "owner got WETH back");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(tokenId), user, "empty NFT returned");
        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(tokenId);
        assertEq(liq, 0, "liquidity removed");
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0, "guard keeps nothing");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "guard keeps nothing");
        assertEq(IERC20(AERO).balanceOf(proxy), 0, "proxy gets nothing");
    }

    function test_onlyOwnerOrReactiveThroughProxy() public {
        vm.prank(user);
        guard.deposit(tokenId, true, 3 hours);
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.close(tokenId);
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.withdraw(tokenId);
        // not the proxy
        vm.prank(stranger);
        vm.expectRevert();
        guard.closeByReactive(reactive, tokenId);
        // the proxy, but relaying some other reactive contract
        vm.prank(proxy);
        vm.expectRevert();
        guard.closeByReactive(stranger, tokenId);
        // the reactive contract can close, never withdraw
        vm.prank(proxy);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.withdraw(tokenId);
    }

    function test_ownerWithdrawsPositionIntact() public {
        (,,,,,,, uint128 before,,,,) = INonfungiblePositionManager(NPM).positions(tokenId);
        vm.startPrank(user);
        guard.deposit(tokenId, true, 3 hours);
        guard.withdraw(tokenId);
        vm.stopPrank();
        assertEq(INonfungiblePositionManager(NPM).ownerOf(tokenId), user);
        (,,,,,,, uint128 afterLiq,,,,) = INonfungiblePositionManager(NPM).positions(tokenId);
        assertEq(afterLiq, before, "liquidity untouched");
    }

    // ---- one-step entry (`open`) and the owner's safety ----

    function _openParams(uint256 a0, uint256 a1) internal pure returns (PositionGuard.OpenParams memory) {
        return PositionGuard.OpenParams({
            pool: POOL,
            amount0: a0,
            amount1: a1,
            halfWidth: 5,
            amount0Min: 0,
            amount1Min: 0,
            stake: true,
            graceSeconds: 3 hours
        });
    }

    function _openAsUser() internal returns (uint256 id) {
        deal(AERO, user, 1_000e18);
        deal(WETH, user, 1e18);
        vm.startPrank(user);
        IERC20Approve(AERO).approve(address(guard), type(uint256).max);
        IERC20Approve(WETH).approve(address(guard), type(uint256).max);
        id = guard.open(_openParams(1_000e18, 1e18));
        vm.stopPrank();
    }

    function test_open_mintsAroundPrice_stakes_refundsTheRest() public {
        uint256 id = _openAsUser();

        (address owner, address gauge) = guard.guarded(id);
        assertEq(owner, user, "user owns the guarded position");
        assertEq(gauge, ICLPool(POOL).gauge(), "staked in the pool's gauge");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), gauge, "NFT sits in the gauge");

        (,,,,, int24 lower, int24 upper, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(id);
        (, int24 tick) = _slot0();
        assertTrue(lower <= tick && tick < upper, "current price inside the range");
        assertEq(upper - lower, 11 * SPACING, "range is 2 x halfWidth + 1 spacings");
        assertGt(liq, 0, "liquidity added");

        // One side is used up, the other comes back; the guard keeps nothing.
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0, "no AERO left in the guard");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "no WETH left in the guard");
        assertTrue(IERC20(AERO).balanceOf(user) > 0 || IERC20(WETH).balanceOf(user) > 0, "unused side refunded");
        console2.log("refunded AERO:", IERC20(AERO).balanceOf(user));
        console2.log("refunded WETH:", IERC20(WETH).balanceOf(user));
    }

    function test_open_rejectsFakePool() public {
        PositionGuard.OpenParams memory p = _openParams(1e18, 1e18);
        p.pool = address(new FakePool(AERO, WETH));
        vm.prank(user);
        vm.expectRevert(PositionGuard.UnknownPool.selector);
        guard.open(p);
    }

    function test_open_rejectsZeroWidth() public {
        PositionGuard.OpenParams memory p = _openParams(1e18, 1e18);
        p.halfWidth = 0;
        vm.prank(user);
        vm.expectRevert(PositionGuard.BadWidth.selector);
        guard.open(p);
    }

    /// Safety: after a one-step entry nobody but the owner can touch the money, and the owner
    /// can leave at any moment and gets everything back.
    function test_open_strangerCannotTouch_ownerExitsWithEverything() public {
        uint256 id = _openAsUser();
        uint256 a0 = IERC20(AERO).balanceOf(user);
        uint256 w0 = IERC20(WETH).balanceOf(user);

        vm.startPrank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.close(id);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.withdraw(id);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        guard.close(id);

        assertGt(IERC20(AERO).balanceOf(user), a0, "owner got AERO back (tokens + rewards)");
        assertGt(IERC20(WETH).balanceOf(user), w0, "owner got WETH back");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user, "empty NFT returned");
        assertEq(IERC20(AERO).balanceOf(stranger), 0, "stranger got nothing");
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0, "guard keeps nothing");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "guard keeps nothing");
    }

    function test_open_ownerCanTakeNftBackUntouched() public {
        uint256 id = _openAsUser();
        (,,,,,,, uint128 liqBefore,,,,) = INonfungiblePositionManager(NPM).positions(id);
        vm.prank(user);
        guard.withdraw(id);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user);
        (,,,,,,, uint128 liqAfter,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertEq(liqAfter, liqBefore, "liquidity untouched");
    }

    function test_unstakedDeposit_ownerCloses() public {
        vm.startPrank(user);
        guard.deposit(tokenId, false, 0);
        uint256 w0 = IERC20(WETH).balanceOf(user);
        guard.close(tokenId);
        vm.stopPrank();
        assertGt(IERC20(WETH).balanceOf(user), w0);
    }

    // ---- one-step entry from a single token (`openWith`) ----

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDC_AERO = 0xD0Acf293547457Fb4fE9eE32CA93e89497626816; // CL200
    address constant WETH_USDC = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // CL50

    function _leg(address pool, uint256 amountIn, uint256 minOut) internal pure returns (PositionGuard.SwapLeg memory) {
        return PositionGuard.SwapLeg({pool: pool, amountIn: amountIn, minOut: minOut});
    }

    function _fundUsdc(uint256 amount) internal {
        deal(USDC, user, amount);
        deal(AERO, user, 0);
        deal(WETH, user, 0);
        vm.prank(user);
        IERC20Approve(USDC).approve(address(guard), type(uint256).max);
    }

    function test_openWith_usdcOnly_opensStakesAndLeavesNothingBehind() public {
        _fundUsdc(200e6);
        vm.prank(user);
        uint256 id =
            guard.openWith(USDC, 200e6, _leg(USDC_AERO, 100e6, 1), _leg(WETH_USDC, 100e6, 1), _openParams(0, 0));

        (address owner, address gauge) = guard.guarded(id);
        assertEq(owner, user);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), gauge, "staked");
        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertGt(liq, 0, "liquidity added");

        assertEq(IERC20(USDC).balanceOf(address(guard)), 0, "no USDC left in the guard");
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0, "no AERO left in the guard");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "no WETH left in the guard");
        console2.log("leftover back to user - AERO:", IERC20(AERO).balanceOf(user));
        console2.log("leftover back to user - WETH:", IERC20(WETH).balanceOf(user));
        console2.log("leftover back to user - USDC:", IERC20(USDC).balanceOf(user));

        // And the owner can still leave at once with everything.
        vm.prank(user);
        guard.close(id);
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
        console2.log("after close - AERO:", IERC20(AERO).balanceOf(user));
        console2.log("after close - WETH:", IERC20(WETH).balanceOf(user));
    }

    function test_openWith_payWithPoolToken_onlyOneSwap() public {
        deal(WETH, user, 0.1e18);
        deal(AERO, user, 0);
        vm.startPrank(user);
        IERC20Approve(WETH).approve(address(guard), type(uint256).max);
        // Pay in WETH (token1): half is swapped into AERO in the same pool, the rest goes in as is.
        uint256 id = guard.openWith(WETH, 0.1e18, _leg(POOL, 0.05e18, 1), _leg(address(0), 0, 0), _openParams(0, 0));
        vm.stopPrank();
        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(NPM).positions(id);
        assertGt(liq, 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0);
    }

    function test_openWith_priceMoved_revertsAndUserKeepsMoney() public {
        _fundUsdc(200e6);
        vm.prank(user);
        vm.expectRevert(PositionGuard.TooLittleReceived.selector);
        // Asking for an absurd amount of AERO for 100 USDC = the price "moved" against us.
        guard.openWith(USDC, 200e6, _leg(USDC_AERO, 100e6, 1_000_000e18), _leg(WETH_USDC, 100e6, 1), _openParams(0, 0));
        assertEq(IERC20(USDC).balanceOf(user), 200e6, "nothing was taken");
    }

    function test_openWith_rejectsWrongSwapPoolAndBadSplit() public {
        _fundUsdc(200e6);
        vm.startPrank(user);
        // USDC/WETH pool offered as the route to AERO
        vm.expectRevert(PositionGuard.BadSwapPool.selector);
        guard.openWith(USDC, 200e6, _leg(WETH_USDC, 100e6, 1), _leg(WETH_USDC, 100e6, 1), _openParams(0, 0));
        // swaps add up to more than was paid
        vm.expectRevert(PositionGuard.BadSplit.selector);
        guard.openWith(USDC, 100e6, _leg(USDC_AERO, 100e6, 1), _leg(WETH_USDC, 100e6, 1), _openParams(0, 0));
        vm.stopPrank();
    }

    function test_swapCallback_onlyThePoolBeingSwappedIn() public {
        deal(USDC, address(guard), 50e6); // even if the guard held something
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotSwapPool.selector);
        guard.uniswapV3SwapCallback(int256(50e6), 0, abi.encode(USDC));
        // a real pool calling on its own, outside a swap, gets nothing either
        vm.prank(USDC_AERO);
        vm.expectRevert(PositionGuard.NotSwapPool.selector);
        guard.uniswapV3SwapCallback(int256(50e6), 0, abi.encode(USDC));
    }

    // ---- exit into a single token (`closeTo`) ----

    function _openWithUsdc() internal returns (uint256 id) {
        _fundUsdc(200e6);
        vm.prank(user);
        id = guard.openWith(USDC, 200e6, _leg(USDC_AERO, 100e6, 1), _leg(WETH_USDC, 100e6, 1), _openParams(0, 0));
    }

    function test_closeTo_fullCircle_usdcInUsdcOut() public {
        uint256 id = _openWithUsdc();
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        vm.warp(block.timestamp + 1 days);

        vm.prank(user);
        uint256 out = guard.closeTo(id, USDC, _leg(USDC_AERO, 0, 1), _leg(WETH_USDC, 0, 1));

        uint256 got = IERC20(USDC).balanceOf(user) - usdcBefore;
        console2.log("USDC in: 200, USDC back (6 decimals):", got);
        assertEq(got, out, "reported amount matches");
        assertGt(got, 190e6, "round trip loses only swap fees");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user, "empty NFT returned");
        (address owner,) = guard.guarded(id);
        assertEq(owner, address(0), "no longer guarded");
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0, "guard keeps nothing");
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0, "guard keeps nothing");
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "guard keeps nothing");
    }

    function test_closeTo_priceMoved_revertsAndPositionStays() public {
        uint256 id = _openWithUsdc();
        vm.prank(user);
        vm.expectRevert(PositionGuard.TooLittleReceived.selector);
        guard.closeTo(id, USDC, _leg(USDC_AERO, 0, 1_000_000e6), _leg(WETH_USDC, 0, 1));
        (address owner,) = guard.guarded(id);
        assertEq(owner, user, "still guarded, nothing lost");
    }

    function test_closeTo_ownerOnly() public {
        uint256 id = _openWithUsdc();
        vm.prank(stranger);
        vm.expectRevert(PositionGuard.NotOwner.selector);
        guard.closeTo(id, USDC, _leg(USDC_AERO, 0, 1), _leg(WETH_USDC, 0, 1));
    }

    function test_closeTo_intoPoolToken_oneSwap() public {
        uint256 id = _openWithUsdc();
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        vm.prank(user);
        // all out in WETH: AERO (token0) is swapped in the AERO/WETH pool itself
        guard.closeTo(id, WETH, _leg(POOL, 0, 1), _leg(address(0), 0, 0));
        assertGt(IERC20(WETH).balanceOf(user), wethBefore);
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0);
        assertEq(IERC20(WETH).balanceOf(address(guard)), 0);
    }
}

/// Looks like a pool but is not one the factory made.
contract FakePool {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function tickSpacing() external pure returns (int24) {
        return 200;
    }
}
