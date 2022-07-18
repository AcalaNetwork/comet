// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./CometModified.sol";
import "./CometModifiedConfiguration.sol";

contract CometModifiedFactory is CometModifiedConfiguration {
    function clone(Configuration calldata config) external returns (address) {
        return address(new CometModified(config));
    }
}