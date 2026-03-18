import { NativeModules, Platform } from 'react-native';

type InterlaceImageNativeModule = {
  generateInterlacedImage: (imagePaths: string[]) => Promise<string>;
};

const { InterlaceImage } = NativeModules as {
  InterlaceImage?: InterlaceImageNativeModule;
};

export async function generateInterlacedImage(imagePaths: string[]): Promise<string> {
  if (Platform.OS !== 'ios') {
    throw new Error('`InterlaceImage` 仅支持 iOS');
  }
  if (!InterlaceImage?.generateInterlacedImage) {
    throw new Error('原生模块 `InterlaceImage` 未注册/未链接');
  }

  if (!Array.isArray(imagePaths) || imagePaths.length === 0) {
    throw new Error('imagePaths 不能为空');
  }

  return await InterlaceImage.generateInterlacedImage(imagePaths);
}

