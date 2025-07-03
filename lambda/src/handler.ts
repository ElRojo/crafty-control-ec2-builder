import {
  EC2Client,
  StartInstancesCommand,
  StopInstancesCommand
} from "@aws-sdk/client-ec2";
import { Handler } from "aws-lambda";

const instanceId = process.env.INSTANCE_ID;
const action = process.env.ACTION;
const region = process.env.AWS_REGION;

if (!instanceId) {
  throw new Error("INSTANCE_ID environment variable not set");
}
 
if (!action) {
  throw new Error("ACTION environment variable not set");
}

if (!region) {
  throw new Error("AWS_REGION environment variable not set");
}

const ec2Client = new EC2Client({ region });

export const handler: Handler = async () => {
  try {
    if (action === "start") {
      console.info(`Starting EC2 instance: ${instanceId}`);
      await ec2Client.send(
        new StartInstancesCommand({ InstanceIds: [instanceId] })
      );
    } else if (action === "stop") {
      console.info(`Stopping EC2 instance: ${instanceId}`);
      await ec2Client.send(
        new StopInstancesCommand({ InstanceIds: [instanceId] })
      );
    } else {
      throw new Error(`Unsupported action: ${action}`);
    }

    console.info(`Successfully ${action}ed instance ${instanceId}`);
  } catch (error) {
    console.error(`Failed to ${action} instance ${instanceId}:`, error);
    throw error;
  }
};
