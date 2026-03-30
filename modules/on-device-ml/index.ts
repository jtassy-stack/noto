let module: { isAvailable(): boolean; generateSummary(context: string, instructions: string): Promise<string> } | null = null;

try {
  const native = require('./src/OnDeviceMlModule').default;
  module = native;
} catch {}

export function isAvailable(): boolean {
  try {
    return module?.isAvailable() ?? false;
  } catch {
    return false;
  }
}

export async function generateSummary(
  context: string,
  instructions: string
): Promise<string> {
  if (!module) throw new Error("OnDeviceMl not available");
  return module.generateSummary(context, instructions);
}
