import OnDeviceMlModule from './src/OnDeviceMlModule';

export function isAvailable(): boolean {
  return OnDeviceMlModule.isAvailable();
}

export async function generateSummary(
  context: string,
  instructions: string
): Promise<string> {
  return OnDeviceMlModule.generateSummary(context, instructions);
}
