// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./CometModifiedConfiguration.sol";
import "../Configurator.sol";

/**
 * @title A modified version of Configurator
 * @notice This is solely used for testing upgrades
 * @author Compound
 */
contract ConfiguratorModified is Configurator, CometModifiedConfiguration {

    mapping(address => ModifiedConfiguration) internal configuratorParams;

    constructor() Configurator() {}

    /**
     * @notice Sets the entire Configuration for a Comet proxy
     * @dev Note: All params can later be updated by the governor except for `baseToken` and `trackingIndexScale`
     **/
    function setConfiguration(address cometProxy, ModifiedConfiguration calldata newConfiguration) override external {
        if (msg.sender != governor) revert Unauthorized();
        ModifiedConfiguration memory oldConfiguration = configuratorParams[cometProxy];
        if (oldConfiguration.baseToken != address(0)) revert ConfigurationAlreadyExists();

        configuratorParams[cometProxy] = newConfiguration;
        emit SetConfiguration(cometProxy, oldConfiguration, newConfiguration);
    }
}
