import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import type { Construct } from 'constructs';

export interface FirmwareDeployStackProps extends cdk.StackProps {
  imageBucketName: string;
  /** リポジトリルートからの atomcam_tools.zip の絶対パス */
  firmwareZipPath: string;
  /** configs/mocula.ver の内容（例: "0.2.0"） */
  version: string;
}

// BucketDeployment に単一の zip ファイルをそのまま (中身を展開させずに) デプロイするための対処。
// Source.asset() が directory ではなく zip ファイル単体を指している場合、
// BucketDeployment はその zip の中身を展開してデスティネーションに配置してしまう。
// atomcam_tools.zip 自体を1つのオブジェクトとして配置したいので、
// 「atomcam_tools.zip だけを含むディレクトリ」を用意してそこを Source.asset() に渡す。
function stageFirmwareZip(firmwareZipPath: string, version: string): string {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), `atomcam-firmware-${version}-`));
  fs.copyFileSync(firmwareZipPath, path.join(stagingDir, 'atomcam_tools.zip'));
  return stagingDir;
}

export class FirmwareDeployStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: FirmwareDeployStackProps) {
    super(scope, id, props);

    if (!fs.existsSync(props.firmwareZipPath)) {
      throw new Error(
        `Firmware zip not found: ${props.firmwareZipPath} (run "make build" first to produce atomcam_tools.zip)`
      );
    }

    const stagingDir = stageFirmwareZip(props.firmwareZipPath, props.version);
    const imageBucket = s3.Bucket.fromBucketName(this, 'ImageBucket', props.imageBucketName);

    new s3deploy.BucketDeployment(this, 'FirmwareDeployment', {
      sources: [s3deploy.Source.asset(stagingDir)],
      destinationBucket: imageBucket,
      destinationKeyPrefix: `firmware/ota/${props.version}`,
      extract: true,
      prune: true,
    });
  }
}
