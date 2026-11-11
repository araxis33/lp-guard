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
        (tokenId,,,) = INonfungiblePositionManager(NPM).mint(
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

    function test_unstakedDeposit_ownerCloses() public {
        vm.startPrank(user);
        guard.deposit(tokenId, false, 0);
        uint256 w0 = IERC20(WETH).balanceOf(user);
        guard.close(tokenId);
        vm.stopPrank();
        assertGt(IERC20(WETH).balanceOf(user), w0);
    }
}
