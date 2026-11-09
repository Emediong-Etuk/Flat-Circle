// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FlatCircleFactory} from "../src/FlatCircleFactory.sol";

/// @notice Deploys FlatCircleFactory and writes deployments/<chainId>.json.
/// Mainnet:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --account flat-deployer --broadcast \
///     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
/// Then `node ../scripts/record-deployment.mjs` adds the exact block and tx hash from the broadcast log.
contract Deploy is Script {
    address internal constant DEFAULT_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant DEFAULT_WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address internal constant DEFAULT_BURN = 0x000000000000000000000000000000000000dEaD;

    function run() external returns (FlatCircleFactory factory) {
        address usdg = vm.envOr("USDG_ADDRESS", DEFAULT_USDG);
        address wif = vm.envOr("WIF_ADDRESS", DEFAULT_WIF);
        address burn = vm.envOr("BURN_ADDRESS", DEFAULT_BURN);
        require(usdg.code.length > 0 && wif.code.length > 0, "token not deployed on this chain");

        // On Arbitrum RPCs, the block number seen here is the L2 block: a safe lower bound for log queries.
        uint256 blockHint = block.number;

        vm.startBroadcast();
        factory = new FlatCircleFactory(usdg, wif, burn);
        vm.stopBroadcast();

        console2.log("FlatCircleFactory:", address(factory));
        console2.log("USDG decimals:", factory.usdgDecimals());
        console2.log("maxContribution:", factory.maxContribution());

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "usdg", usdg);
        vm.serializeAddress(k, "wif", wif);
        vm.serializeAddress(k, "burnAddress", burn);
        vm.serializeUint(k, "deployBlockHint", blockHint);
        string memory json = vm.serializeAddress(k, "factory", address(factory));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
