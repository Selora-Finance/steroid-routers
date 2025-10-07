import { createWriteStream, existsSync, readFileSync } from 'fs';
import { SeloraV2Router, SeloraV3Router, SwapExecutor } from '../types/ethers-contracts';
import Constants from './constants.json';
import { deployContract, getContractAtAddress, parseCLIArgs } from './helpers';
import { network } from 'hardhat';
import { join } from 'path';
import { writeFile } from 'fs/promises';

// Output definition
interface Output {
  routers: string[];
  swapExecutor: string;
}

async function core() {
  const cliArgs = parseCLIArgs();
  const networkName = cliArgs.values.network as string;
  // Get constants
  const constants = Constants[networkName as keyof typeof Constants];
  const routers: string[] = [];
  // Deploy SeloraV2
  const seloraV2 = await deployContract<SeloraV2Router>(
    networkName,
    'SeloraV2Router',
    undefined,
    constants.seloraV2Router,
  );
  routers.push(await seloraV2.getAddress());
  // Deploy SeloraV3
  const seloraV3 = await deployContract<SeloraV3Router>(
    networkName,
    'SeloraV3Router',
    undefined,
    constants.seloraV3Router,
    constants.seloraV3Factory,
  );
  routers.push(await seloraV3.getAddress());

  const { networkConfig } = await network.connect({ network: networkName });
  const outputDirectory = 'scripts/deployments';
  const outputFile = join(process.cwd(), outputDirectory, `CoreOutput-${String(networkConfig.chainId)}.json`);
  const outputBuffer = readFileSync(outputFile);
  const output: Output = JSON.parse(outputBuffer.toString());

  // Swap executor
  const swapExecutor = await getContractAtAddress<SwapExecutor>(networkName, 'SwapExecutor', output.swapExecutor);
  await swapExecutor.setTrustedTokens(constants.trustedTokens);
  await Promise.all(output.routers.map(router => swapExecutor.switchRouterActiveStatus(router)));
  await swapExecutor.addRouters(routers);

  output.routers = routers;

  try {
    if (!existsSync(outputFile)) {
      const ws = createWriteStream(outputFile);
      ws.write(JSON.stringify(output, null, 2));
      ws.end();
    } else {
      await writeFile(outputFile, JSON.stringify(output, null, 2));
    }
  } catch (err) {
    console.error(`Error writing output file: ${err}`);
  }
}

core().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
