// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DustExecutor} from "../src/DustExecutor.sol";

contract DustExecutorTest is Test {
    DustExecutor internal executor;

    address internal owner = address(this);
    address internal weth = makeAddr("weth");
    address internal permit2 = makeAddr("permit2");
    address internal user = makeAddr("user");
    address internal router = makeAddr("router");

    function setUp() public {
        executor = new DustExecutor(weth, permit2);
    }

    function test_Constructor() public view {
        assertEq(executor.owner(), owner);
        assertEq(executor.WETH(), weth);
        assertEq(address(executor.PERMIT2()), permit2);
        assertEq(executor.feeCollector(), owner);
        assertEq(executor.feeBps(), 100);
        assertEq(executor.MAX_FEE_BPS(), 300);
    }

    function test_Constructor_RevertOnZeroWeth() public {
        vm.expectRevert("WETH zero");
        new DustExecutor(address(0), permit2);
    }

    function test_Constructor_RevertOnZeroPermit2() public {
        vm.expectRevert("Permit2 zero");
        new DustExecutor(weth, address(0));
    }

    function test_SetRouter() public {
        executor.setRouter(router, true);
        assertTrue(executor.allowedRouters(router));
        executor.setRouter(router, false);
        assertFalse(executor.allowedRouters(router));
    }

    function test_SetRouter_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not owner");
        executor.setRouter(router, true);
    }

    function test_SetFeeBps() public {
        executor.setFeeBps(250);
        assertEq(executor.feeBps(), 250);
    }

    function test_SetFeeBps_RevertAboveMax() public {
        vm.expectRevert("fee too high");
        executor.setFeeBps(301);
    }

    function test_SetFeeCollector() public {
        executor.setFeeCollector(user);
        assertEq(executor.feeCollector(), user);
    }

    function test_SetFeeCollector_RevertZero() public {
        vm.expectRevert("collector zero");
        executor.setFeeCollector(address(0));
    }

    function test_TransferOwnership() public {
        executor.transferOwnership(user);
        assertEq(executor.owner(), user);
    }

    function test_TransferOwnership_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not owner");
        executor.transferOwnership(user);
    }

    function test_ConvertDust_RevertExpiredDeadline() public {
        DustExecutor.Swap[] memory swaps = new DustExecutor.Swap[](1);
        vm.warp(1_000);
        vm.expectRevert("Deadline expired");
        executor.convertDust(swaps, 999);
    }

    function test_ConvertDust_RevertNoSwaps() public {
        DustExecutor.Swap[] memory swaps = new DustExecutor.Swap[](0);
        vm.expectRevert("No swaps");
        executor.convertDust(swaps, block.timestamp + 1);
    }

    function test_RescueETH_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not owner");
        executor.rescueETH(user, 1 ether);
    }
}
