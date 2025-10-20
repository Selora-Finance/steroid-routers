import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const artifactsPath = path.join(__dirname, '../artifacts/contracts');
const abisPath = path.join(__dirname, './abis');

function recursivelyTraverseArtifactsPath(pth: string, previousPaths: string[] = []) {
  const directories = fs.readdirSync(pth);
  const paths = previousPaths.indexOf(pth) !== -1 ? previousPaths : previousPaths.concat(pth);

  for (const directory of directories) {
    const fullPath = path.join(pth, directory);
    const stat = fs.statSync(fullPath);
    if (stat.isDirectory()) {
      paths.push(fullPath);
      recursivelyTraverseArtifactsPath(fullPath, paths);
    } else paths.push(fullPath);
  }

  return paths;
}

function saveFiles() {
  // Mkdir if not exists
  if (!fs.existsSync(abisPath)) fs.mkdirSync(abisPath);
  const artifacts = recursivelyTraverseArtifactsPath(artifactsPath);
  const filesWithinArtifacts = artifacts.filter(ar => fs.statSync(ar).isFile());
  // Read each file and derive object structure
  filesWithinArtifacts
    .filter(file => path.extname(file) === '.json')
    .forEach(file => {
      const bufferContent = fs.readFileSync(file);
      const json = JSON.parse(bufferContent.toString());

      if (Object.hasOwn(json, 'abi')) {
        const newPath = path.join(abisPath, path.basename(file));
        // File exists?
        const fileExists = fs.existsSync(newPath);

        if (!fileExists) {
          const ws = fs.createWriteStream(newPath);
          ws.write(JSON.stringify(json.abi, null, 2));
          ws.end();
        } else {
          fs.writeFileSync(newPath, JSON.stringify(json.abi, null, 2));
        }
      }
    });
}

saveFiles();
