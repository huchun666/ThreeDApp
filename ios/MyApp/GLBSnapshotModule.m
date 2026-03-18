#import <React/RCTBridgeModule.h>
#import <React/RCTUIManager.h>
#import <React/RCTBridge.h>
#import "MyApp-Swift.h"

@interface GLBSnapshot : NSObject <RCTBridgeModule>
@property (nonatomic, weak) RCTBridge *bridge;
@end

@implementation GLBSnapshot
@synthesize bridge = _bridge;

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(capture:(nonnull NSNumber *)reactTag
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self.bridge.uiManager
      addUIBlock:^(__unused RCTUIManager *uiManager,
                   NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        UIView *v = viewRegistry[reactTag];
        if (![v isKindOfClass:[GLBSceneContainerView class]]) {
          reject(@"E_VIEW", @"GLB 原生视图未找到（请确认 ref 指向 GLBSceneView）", nil);
          return;
        }
        GLBSceneContainerView *glb = (GLBSceneContainerView *)v;
        NSString *b64 = [glb captureSnapshotToBase64];
        if (b64 != nil) {
          resolve(b64);
        } else {
          reject(@"E_SNAP", @"离屏截图失败（场景或相机未就绪）", nil);
        }
      }];
}

RCT_EXPORT_METHOD(captureMulti:(nonnull NSNumber *)reactTag
                  count:(nonnull NSNumber *)count
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self.bridge.uiManager
      addUIBlock:^(__unused RCTUIManager *uiManager,
                   NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        UIView *v = viewRegistry[reactTag];
        if (![v isKindOfClass:[GLBSceneContainerView class]]) {
          reject(@"E_VIEW", @"GLB 原生视图未找到（请确认 ref 指向 GLBSceneView）", nil);
          return;
        }
        GLBSceneContainerView *glb = (GLBSceneContainerView *)v;
        NSArray<NSString *> *list = [glb captureSnapshotsAround:count];
        if (list != nil && list.count > 0) {
          resolve(list);
        } else {
          reject(@"E_SNAP_MULTI", @"多机位离屏截图失败（场景或相机未就绪）", nil);
        }
      }];
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

@end
