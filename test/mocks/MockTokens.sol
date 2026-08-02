// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract RevertingTransferFromToken is MockToken {
    constructor() MockToken("BINI V1", "BINI1", 12) {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("LOCK_FAILED");
    }
}

contract FeeOnTransferToken is MockToken {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockToken(name_, symbol_, decimals_) {}

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(msg.sender, to, value - 1);
        _burn(msg.sender, 1);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value - 1);
        _burn(from, 1);
        return true;
    }
}
