// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "../CometConfiguration.sol";

/**
 * @title A modified version of Compound's Comet Configuration Interface
 * @author Compound
 */
contract CometModifiedConfiguration is CometConfiguration {
    struct ModifiedConfiguration {
        Configuration cometConfiguration;

        uint104 newStorageSlot;
    }
}
