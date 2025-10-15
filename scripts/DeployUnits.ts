import { network } from 'hardhat';
import { createWriteStream, existsSync, readFileSync } from 'fs';
import { writeFile } from 'fs/promises';
import { join } from 'path';
import { V2SwapExecutor, V3SwapExecutor } from '../types/ethers-contracts';
import Constants from './constants.json';
import { deployContract, parseCLIArgs } from './helpers';

// Output definition
interface Output {
  routers: string[];
  swapExecutor: string;
  v2SwapExecutor: string;
  v3SwapExecutor: string;
}

async function core() {
  // Get CLI args
  const cliArgs = parseCLIArgs();
  const networkName = cliArgs.values.network as string;
  // Get constants
  const constants = Constants[networkName as keyof typeof Constants];

  // Deploy V2 Swap Executor
  const v2SwapExecutor = await deployContract<V2SwapExecutor>(
    networkName,
    'V2SwapExecutor',
    undefined,
    constants.team,
    constants.seloraV2Router,
    '1000',
    constants.weth,
    constants.trustedTokens,
  );
  // Deploy V3 Swap Executor
  const v3SwapExecutor = await deployContract<V3SwapExecutor>(
    networkName,
    'V3SwapExecutor',
    undefined,
    constants.team,
    constants.seloraV3Router,
    constants.seloraV3Factory,
    '1000',
    constants.weth,
    constants.trustedTokens,
  );

  const { networkConfig } = await network.connect({ network: networkName });
  const outputDirectory = 'scripts/deployments';
  const outputFile = join(process.cwd(), outputDirectory, `CoreOutput-${String(networkConfig.chainId)}.json`);
  const output: Output = JSON.parse(readFileSync(outputFile).toString()) as Output;
  output.v2SwapExecutor = await v2SwapExecutor.getAddress();
  output.v3SwapExecutor = await v3SwapExecutor.getAddress();

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
