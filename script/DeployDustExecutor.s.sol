// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {DustExecutor} from "../src/DustExecutor.sol";

/// @notice Deploys DustExecutor to Base and allow-lists the Uniswap routers
///         the backend produces calldata for.
///
/// Usage:
///   forge script script/DeployDustExecutor.s.sol:DeployDustExecutor \
///     --rpc-url base --broadcast --verify
contract DeployDustExecutor is Script {
    // Base mainnet canonical addresses
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Uniswap on Base
    address constant SWAP_ROUTER_02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;

    function run() external returns (DustExecutor dustExecutor) {
        address weth = vm.envOr("WETH", BASE_WETH);
        address permit2 = vm.envOr("PERMIT2", PERMIT2);
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        dustExecutor = new DustExecutor(weth, permit2);

        // Allow-list the routes the backend can build calldata for.
        dustExecutor.setRouter(SWAP_ROUTER_02, true);
        dustExecutor.setRouter(UNIVERSAL_ROUTER, true);

        vm.stopBroadcast();

        console2.log("DustExecutor:", address(dustExecutor));
        console2.log("owner:       ", dustExecutor.owner());
        console2.log("feeCollector:", dustExecutor.feeCollector());
        console2.log("feeBps:      ", dustExecutor.feeBps());
    }
}
