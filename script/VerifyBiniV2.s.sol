// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {BiniMigrationVault} from "../src/BiniMigrationVault.sol";

contract VerifyBiniV2 is Script {
    function run() external view {
        BiniTokenV2 token = BiniTokenV2(vm.envAddress("BINI_V2_PROXY"));
        BiniMigrationVault vault = BiniMigrationVault(vm.envAddress("MIGRATION_VAULT"));
        address timelock = vm.envAddress("ADMIN_TIMELOCK");
        address genesis = vm.envAddress("GENESIS_DISTRIBUTION_SAFE");

        require(keccak256(bytes(token.name())) == keccak256("Binibit"), "BAD_NAME");
        require(keccak256(bytes(token.symbol())) == keccak256("BINI"), "BAD_SYMBOL");
        require(token.decimals() == 18, "BAD_DECIMALS");
        require(token.totalSupply() == 1_000_000_000 ether, "BAD_SUPPLY");
        require(token.balanceOf(genesis) <= token.totalSupply(), "BAD_GENESIS_BALANCE");
        require(token.defaultAdmin() == timelock, "BAD_ADMIN");
        require(!token.marketOpen(), "MARKET_OPEN");
        require(address(vault.v2Token()) == address(token), "BAD_VAULT_V2");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), timelock), "BAD_VAULT_ADMIN");
    }
}
