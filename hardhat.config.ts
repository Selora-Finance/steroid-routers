import type { HardhatUserConfig } from 'hardhat/config';

import hardhatToolboxMochaEthersPlugin from '@nomicfoundation/hardhat-toolbox-mocha-ethers';
import hardhatKeystore from '@nomicfoundation/hardhat-keystore';
import hardhatTypechain from '@nomicfoundation/hardhat-typechain';
import hardhatAbiExporter from '@solidstate/hardhat-abi-exporter';
import { configVariable } from 'hardhat/config';

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxMochaEthersPlugin, hardhatKeystore, hardhatAbiExporter, hardhatTypechain],
  solidity: {
    profiles: {
      default: {
        version: '0.8.28',
      },
      production: {
        version: '0.8.28',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
  },
  networks: {
    hardhatMainnet: {
      type: 'edr-simulated',
      chainType: 'l1',
    },
    hardhatOp: {
      type: 'edr-simulated',
      chainType: 'op',
    },
    sepolia: {
      type: 'http',
      chainType: 'l1',
      url: configVariable('SEPOLIA_RPC_URL'),
      accounts: [configVariable('PRIVATE_KEY')],
    },
    fluentTestnet: {
      url: configVariable('FLUENT_TESTNET_RPC_URL'),
      chainId: 20994,
      accounts: [configVariable('PRIVATE_KEY')],
      gasPrice: 'auto',
      gas: 'auto',
      gasMultiplier: 1,
      type: 'http',
      chainType: 'l1',
    },
  },
  abiExporter: {
    path: './scripts/deployments/abis',
    runOnCompile: true,
    clear: true,
  },
};

export default config;
