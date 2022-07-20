import { DeploymentManager } from '../../../plugins/deployment_manager/DeploymentManager';
import { migration } from '../../../plugins/deployment_manager/Migration';
import { deployNetworkComet } from '../../../src/deploy/Network';
import { exp, wait } from '../../../test/helpers';
import {
  Fauceteer,
  Fauceteer__factory,
  ProxyAdmin,
  ProxyAdmin__factory
} from '../../../build/types';
import { Contract } from 'ethers';

migration('1658337437_deploy_mainnet', {
  prepare: async (deploymentManager: DeploymentManager) => {
    const { ethers } = deploymentManager.hre;
    const signer = await deploymentManager.getSigner();
    const timelock = '0xzzz';
    const pauseGuardian = '0xaaa';

    // Contracts referenced in `configuration.json`.
    let contracts = new Map<string, Contract>([
      ['USDC', usdc],
      ['WBTC', wbtc],
      ['WETH', weth],
      ['COMP', comp],
      ['UNI', uni],
      ['LINK', link],
    ]);

    const { cometProxy, configuratorProxy } = await deployNetworkComet(
      deploymentManager,
      { all: true, timelock: false, governor: false },
      { governor: timelock, pauseGuardian }
    );

    return {
      comet: cometProxy.address,
      configurator: configuratorProxy.address,
    };
  },
  enact: async (deploymentManager: DeploymentManager, contracts) => {
    deploymentManager.putRoots(new Map(Object.entries(contracts)));

    console.log("You should set roots.json to:");
    console.log("");
    console.log("");
    console.log(JSON.stringify(contracts, null, 4));
    console.log("");
  },
  enacted: async (deploymentManager: DeploymentManager) => {
    return false; // XXX
  }
});
