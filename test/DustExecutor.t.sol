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
    address internal helm = makeAddr("helm");

    function setUp() public {
        executor = new DustExecutor(weth, permit2);
    }

    function test_Constructor() public view {
        assertEq(executor.owner(), owner);
        assertEq(executor.WETH(), weth);
        assertEq(address(executor.PERMIT2()), permit2);
        assertEq(executor.ownerWallet(), owner);
        assertEq(executor.MAX_FEE_BPS(), 1000);
        assertEq(executor.ethFeeBps(), 1000);
        assertEq(executor.ethBurnBps(), 300);
        assertEq(executor.helmFeeBps(), 500);
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

    function test_SetOwnerWallet() public {
        executor.setOwnerWallet(user);
        assertEq(executor.ownerWallet(), user);
    }

    function test_SetOwnerWallet_RevertZero() public {
        vm.expectRevert("wallet zero");
        executor.setOwnerWallet(address(0));
    }

    function test_SetOwnerWallet_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not owner");
        executor.setOwnerWallet(user);
    }

    function test_SetFees() public {
        executor.setFees(800, 200, 400);
        assertEq(executor.ethFeeBps(), 800);
        assertEq(executor.ethBurnBps(), 200);
        assertEq(executor.helmFeeBps(), 400);
    }

    function test_SetFees_RevertAboveMax() public {
        vm.expectRevert("fee too high");
        executor.setFees(1001, 0, 500);
    }

    function test_SetFees_RevertBurnExceedsFee() public {
        vm.expectRevert("burn exceeds fee");
        executor.setFees(500, 600, 500);
    }

    function test_SetFees_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not owner");
        executor.setFees(800, 200, 400);
    }

    function test_SetHelmConfig() public {
        executor.setHelmConfig(helm, router, 0x800000, 200, address(0));
        assertEq(executor.helmToken(), helm);
        assertEq(executor.helmRouter(), router);
        assertEq(executor.helmPoolFee(), 0x800000);
        assertEq(executor.helmTickSpacing(), int24(200));
    }

    function test_SetHelmConfig_RevertZero() public {
        vm.expectRevert("zero addr");
        executor.setHelmConfig(address(0), router, 0x800000, 200, address(0));
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
        executor.convertDust(swaps, 999, DustExecutor.OutputMode.ETH, 0);
    }

    function test_ConvertDust_RevertNoSwaps() public {
        DustExecutor.Swap[] memory swaps = new DustExecutor.Swap[](0);
        vm.expectRevert("No swaps");
        executor.convertDust(swaps, block.timestamp + 1, DustExecutor.OutputMode.ETH, 0);
    }

    function test_RescueETH_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not owner");
        executor.rescueETH(user, 1 ether);
    }
}
