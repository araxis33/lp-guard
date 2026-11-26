// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {GuardCore} from "../src/GuardCore.sol";
import {PositionGuard} from "../src/PositionGuard.sol";
import {GuardExt} from "../src/GuardExt.sol";
import {GuardMeter} from "../src/GuardMeter.sol";

/// Everything the guard answers to at its one address: its own functions and GuardExt's (through fallback).
interface IGuard {
    // PositionGuard
    function review(uint256 tokenId) external;
    function reviewByReactive(address) external;
    function checkByReactive(address) external;
    function reviewOne(uint256) external;
    function checkOne(uint256) external;
    function enterParked(uint256, address) external;
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
    function ext() external view returns (address);
    // GuardExt
    function open(GuardCore.OpenParams calldata p) external payable returns (uint256);
    function deposit(uint256 tokenId, bool stake, uint32 graceSeconds) external payable;
    function setReenter(uint256 tokenId, bool on) external;
    function takeParked(uint256 id) external;
    function withdraw(uint256 tokenId) external;
    function setMaxLoss(uint256 tokenId, uint16 maxLossBps) external;
    function setAlternates(uint256 tokenId, address[] calldata pools) external;
    function setPricePool(uint256 tokenId, address via) external;
    function setNetExit(uint256 tokenId, uint16 bpsPerDay) external;
    function close(uint256 tokenId) external;
    function pendingAero(uint256 tokenId) external view returns (uint256);
    function standing(uint256 tokenId) external view returns (uint256, uint256, uint256);
    function alternatesOf(uint256 tokenId) external view returns (address[] memory);
    function netPerDay(uint256 tokenId) external view returns (int256, bool);
    function reviewCount() external view returns (uint256);
    // GuardCore getters
    function meter() external view returns (GuardMeter);
    function guarded(uint256)
        external
        view
        returns (
            address owner,
            address gauge,
            address pool,
            uint16 maxLossBps,
            uint128 entry0,
            uint128 entry1,
            uint256 aeroPaid
        );
    function parked(uint256)
        external
        view
        returns (
            address owner,
            uint64 at,
            address token0,
            address token1,
            uint128 bal0,
            uint128 bal1,
            int24 half,
            uint16 maxLossBps,
            bool stake
        );
    function parkedTotal(address) external view returns (uint256);
    function reenterOn(uint256) external view returns (bool);
    function reviewList(uint256) external view returns (uint256);
    function rangeWatch(uint256) external view returns (uint32 grace, uint64 outSince);
    function netExitBps(uint256) external view returns (uint16);
    function pricePool(uint256) external view returns (address);
    function moveVote(uint256) external view returns (address);
    function TWAP_WINDOW() external view returns (uint32);
}

library GuardDeploy {
    /// Deploys the meter, the extension and the guard, as script/live.sh does.
    function deploy(address npm, address aero, address proxy, address reactive, address sugar)
        internal
        returns (IGuard)
    {
        GuardMeter meter = new GuardMeter(npm, aero, sugar);
        GuardExt ext = new GuardExt(npm, aero, proxy, reactive, sugar, address(meter));
        PositionGuard guard = new PositionGuard(npm, aero, proxy, reactive, sugar, address(meter), address(ext));
        return IGuard(address(guard));
    }
}
