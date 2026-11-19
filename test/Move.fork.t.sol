// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {GuardMeter} from "../src/GuardMeter.sol";
import {INonfungiblePositionManager, ICLPool, IERC20} from "../src/interfaces/IAero.sol";

interface IERC20Approve3 {
    function approve(address, uint256) external returns (bool);
}

/// Moving a position into a pool of the same two tokens that pays more, on a fork of Base.
/// The decision (which pool earns more) is the meter's, tested in Pay/Loss/Price; here it is fixed with
/// mocks so the move itself is tested on the real pools, position manager and gauges.
contract MoveForkTest is Test {
    address constant NPM = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
    address constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SUGAR = 0x0AD09A66af0154a84e86F761313d02d0abB6edd5;
    address constant CL50 = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH/USDC, step 50
    address constant CL100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24; // WETH/USDC, step 100

    PositionGuard guard;
    GuardMeter meter;
    address user = makeAddr("user");
    address proxy = makeAddr("proxy");
    address reactive = makeAddr("reactive");
    uint256 clock;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")), 56_197_000);
        guard = new PositionGuard(NPM, AERO, proxy, reactive, SUGAR);
        meter = guard.meter();
        clock = vm.getBlockTimestamp();
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    function _open() internal returns (uint256 id) {
        deal(WETH, user, 1e18);
        deal(USDC, user, 3_000e6);
        vm.startPrank(user);
        IERC20Approve3(WETH).approve(address(guard), type(uint256).max);
        IERC20Approve3(USDC).approve(address(guard), type(uint256).max);
        id = guard.open(
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
        address[] memory alts = new address[](1);
        alts[0] = CL100;
        guard.setAlternates(id, alts);
        guard.setNetExit(id, 10);
        vm.stopPrank();
    }

    /// The meter says: both pools measured, CL100 earns more.
    function _cl100Wins() internal {
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.measured.selector), abi.encode(true));
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.netRate.selector), abi.encode(int256(0)));
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.bestAlternate.selector), abi.encode(CL100));
        vm.mockCall(
            address(meter), abi.encodeWithSelector(GuardMeter.netPerDay.selector), abi.encode(int256(1e15), true)
        );
    }

    function _review(uint256 id) internal {
        vm.prank(user);
        guard.review(id);
    }

    function test_move_waitsForTwoReviewsInARow() public {
        uint256 id = _open();
        _cl100Wins();
        _skip(1 days);
        _review(id);
        assertEq(guard.moveVote(id), CL100, "first review: a vote, no move");
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "still in the first pool");
    }

    function test_move_secondReview_movesIntoTheBetterPool_keepingEverySetting() public {
        uint256 id = _open();
        _cl100Wins();
        _skip(1 days);
        _review(id);
        _skip(1 days);

        uint256 w0 = IERC20(WETH).balanceOf(user);
        uint256 u0 = IERC20(USDC).balanceOf(user);
        vm.recordLogs();
        uint256 g0 = gasleft();
        _review(id);
        console2.log("gas for a review that moves:", g0 - gasleft());

        (address oldOwner,,,,,,) = guard.guarded(id);
        assertEq(oldOwner, address(0), "the old position is gone");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(id), user, "its empty NFT goes back to the owner");

        uint256 newId = guard.reviewList(0);
        assertTrue(newId != id, "a new position");
        (address owner, address gauge, address pool, uint16 maxLoss,,,) = guard.guarded(newId);
        assertEq(owner, user, "same owner");
        assertEq(pool, CL100, "in the better pool");
        assertEq(gauge, ICLPool(CL100).gauge(), "staked for AERO");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(newId), gauge, "NFT sits in the gauge");
        assertEq(maxLoss, 300, "loss limit kept");
        assertEq(guard.netExitBps(newId), 10, "net exit kept");
        (uint32 grace,) = guard.rangeWatch(newId);
        assertEq(grace, 3 hours, "grace kept");
        address[] memory alts = guard.alternatesOf(newId);
        assertEq(alts.length, 1);
        assertEq(alts[0], CL50, "the old pool becomes the alternate");
        assertEq(guard.reviewCount(), 1, "one position on the lists");

        (,,,,, int24 lo, int24 hi,,,,,) = INonfungiblePositionManager(NPM).positions(newId);
        console2.log("new range width in ticks:", uint256(int256(hi - lo)));
        assertEq(hi - lo, 2100, "same width (old: 41 steps of 50 = 2050, new: 21 steps of 100)");

        assertEq(IERC20(WETH).balanceOf(address(guard)), 0, "guard keeps no WETH");
        assertEq(IERC20(USDC).balanceOf(address(guard)), 0, "guard keeps no USDC");
        assertEq(IERC20(AERO).balanceOf(address(guard)), 0, "guard keeps no AERO");
        console2.log("leftover WETH / USDC to owner:", IERC20(WETH).balanceOf(user) - w0, IERC20(USDC).balanceOf(user) - u0);
    }

    function test_move_fitsTheDailyRunByReactive() public {
        uint256 id = _open();
        _cl100Wins();
        _skip(1 days);
        vm.prank(proxy);
        guard.reviewByReactive{gas: 6_000_000}(reactive);
        _skip(1 days);
        vm.prank(proxy);
        guard.reviewByReactive{gas: 6_000_000}(reactive);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, address(0), "moved inside the daily callback's gas");
        (,, address pool,,,,) = guard.guarded(guard.reviewList(0));
        assertEq(pool, CL100);
    }

    function test_move_notWhileThePriceIsBeingPushed() public {
        uint256 id = _open();
        _cl100Wins();
        _skip(1 days);
        _review(id);
        _skip(1 days);
        // someone moves CL100's price right before the review
        deal(WETH, address(this), 5_000e18);
        Pusher p = new Pusher();
        IERC20(WETH).transfer(address(p), 5_000e18);
        (, int24 before,,,,) = ICLPool(CL100).slot0();
        p.push(CL100, WETH);
        (, int24 afterTick,,,,) = ICLPool(CL100).slot0();
        console2.log("CL100 spot moved by ticks:", int256(before) - int256(afterTick));
        assertGt(int256(before) - int256(afterTick), 100, "the push is big enough to count");
        _review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "no move into a pushed pool");
    }

    function test_move_aWorsePoolClearsTheVote() public {
        uint256 id = _open();
        _cl100Wins();
        _skip(1 days);
        _review(id);
        vm.mockCall(address(meter), abi.encodeWithSelector(GuardMeter.bestAlternate.selector), abi.encode(address(0)));
        _skip(1 days);
        _review(id);
        assertEq(guard.moveVote(id), address(0), "vote cleared");
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "stays");
    }

    function test_move_offWithoutAlternates() public {
        uint256 id = _open();
        vm.prank(user);
        guard.setAlternates(id, new address[](0));
        _cl100Wins();
        _skip(1 days);
        _review(id);
        _skip(1 days);
        _review(id);
        (address owner,,,,,,) = guard.guarded(id);
        assertEq(owner, user, "no alternates: never moves");
    }
}

/// Sells WETH into a WETH/USDC pool (WETH is token0) to move its price.
contract Pusher {
    function push(address pool, address weth) external {
        ICLPool(pool).swap(address(this), true, int256(IERC20(weth).balanceOf(address(this))), 4295128740, abi.encode(weth));
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address t = abi.decode(data, (address));
        IERC20(t).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }
}
