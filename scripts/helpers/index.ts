import { network } from 'hardhat';
import { parseArgs, ParseArgsOptionsConfig } from 'util';

const optionsConfig: ParseArgsOptionsConfig = {
  network: {
    type: 'string',
    short: 'n',
  },
};

export function parseCLIArgs() {
  return parseArgs({
    args: process.argv,
    options: optionsConfig,
    strict: true,
    allowPositionals: true,
  });
}

type Libraries = { [libraryName: string]: string };

export async function deployContract<Type>(
  networkName: string,
  contractName: string,
  libraries?: Libraries,
  ...args: any[]
): Promise<Type> {
  const { ethers } = await network.connect({
    network: networkName,
  });
  const contractFactory = await ethers.getContractFactory(contractName, { libraries });
  const deployment = await contractFactory.deploy(...args);
  const deployed = await deployment.waitForDeployment();
  return deployed as Type;
}

export async function getContractAtAddress<Type>(
  networkName: string,
  contractName: string,
  address: string,
): Promise<Type> {
  const { ethers } = await network.connect({
    network: networkName,
  });
  const contract = await ethers.getContractAt(contractName, address);
  return contract as Type;
}
