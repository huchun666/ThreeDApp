#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(InterlaceImage, NSObject)

RCT_EXTERN_METHOD(generateInterlacedImage:(NSArray *)imagePaths
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end

