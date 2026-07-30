import * as fs from 'node:fs';
import * as path from 'node:path';
import * as yaml from 'js-yaml';

export interface FirmwareDeployConfig {
  aws?: {
    account?: string;
    region?: string;
  };
  imageBucketName: string;
}

export function loadConfig(stage: string): FirmwareDeployConfig {
  const configPath = path.resolve(__dirname, '..', 'config', `${stage}.yml`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`Config file not found: ${configPath}`);
  }
  const raw = fs.readFileSync(configPath, 'utf8');
  return yaml.load(raw) as FirmwareDeployConfig;
}
