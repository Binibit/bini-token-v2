// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

abstract contract StorageFixtureBase is Initializable, UUPSUpgradeable {
    function initialize() external initializer {}

    function _authorizeUpgrade(address) internal pure override {}
}

contract StorageLayoutBaseline is StorageFixtureBase {
    /// @custom:storage-location erc7201:binibit.storage.LayoutFixture
    struct Layout {
        uint256 allocation;
        address custodian;
    }

    bytes32 private constant STORAGE_LOCATION = 0xe68faea53b034fa1aa2bb6535d2f558132653892084ee7c13dcc1df856a39300;

    function layout() external view returns (Layout memory value) {
        value = _layout();
    }

    function _layout() private pure returns (Layout storage value) {
        assembly {
            value.slot := STORAGE_LOCATION
        }
    }
}

contract StorageLayoutIncompatible is StorageFixtureBase {
    /// @custom:storage-location erc7201:binibit.storage.LayoutFixture
    struct Layout {
        address allocation;
        address custodian;
    }

    bytes32 private constant STORAGE_LOCATION = 0xe68faea53b034fa1aa2bb6535d2f558132653892084ee7c13dcc1df856a39300;

    function layout() external view returns (Layout memory value) {
        value = _layout();
    }

    function _layout() private pure returns (Layout storage value) {
        assembly {
            value.slot := STORAGE_LOCATION
        }
    }
}
