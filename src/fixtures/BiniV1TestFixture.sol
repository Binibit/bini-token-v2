// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title BiniV1TestFixture
 * @notice Sepolia/local-only 12-decimal fixture for the BINI V2 migration rehearsal.
 * @dev This is not and must never be configured as the Mainnet BINI V1 token.
 */
contract BiniV1TestFixture is ERC20 {
    error NotFixtureAdmin();

    address public immutable fixtureAdmin;

    constructor(address fixtureAdmin_) ERC20("BINI V1 Test Fixture", "BINI-V1-TEST") {
        require(fixtureAdmin_ != address(0), "ZERO_FIXTURE_ADMIN");
        require(block.chainid != 1, "MAINNET_FORBIDDEN");
        fixtureAdmin = fixtureAdmin_;
    }

    function decimals() public pure override returns (uint8) {
        return 12;
    }

    function mintFixture(address recipient, uint256 amount) external {
        if (msg.sender != fixtureAdmin) revert NotFixtureAdmin();
        _mint(recipient, amount);
    }
}
