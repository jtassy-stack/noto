import { NativeModule, requireNativeModule } from 'expo';

declare class OnDeviceMlModule extends NativeModule {
  isAvailable(): boolean;
  generateSummary(context: string, instructions: string): Promise<string>;
}

export default requireNativeModule<OnDeviceMlModule>('OnDeviceMl');
