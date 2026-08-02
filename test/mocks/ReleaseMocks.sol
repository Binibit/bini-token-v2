// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract ReleaseSafeMock {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }
}

contract ReleaseCodeMock {}
