import { network } from 'hardhat';
import { createWriteStream, existsSync } from 'fs';
import { writeFile } from 'fs/promises';
import { join } from 'path';
import { SeloraV2Router, SeloraV3Router, SwapExecutor } from '../types/ethers-contracts';
import Constants from './constants.json';
import { deployContract, parseCLIArgs } from './helpers';

// Output definition
interface Output {
  routers: string[];
  swapExecutor: string;
}

async function core() {
  // Get CLI args
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

  // Deploy swap executor
  const swapExecutor = await deployContract<SwapExecutor>(
    networkName,
    'SwapExecutor',
    undefined,
    constants.team,
    routers,
    '1000',
    constants.weth,
    constants.trustedTokens,
  );

  const { networkConfig } = await network.connect({ network: networkName });
  const outputDirectory = 'scripts/deployments';
  const outputFile = join(process.cwd(), outputDirectory, `CoreOutput-${String(networkConfig.chainId)}.json`);

  const output: Output = { routers, swapExecutor: await swapExecutor.getAddress() };

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
