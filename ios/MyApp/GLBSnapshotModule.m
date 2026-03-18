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

RCT_EXPORT_METHOD(captureMultiToFiles:(nonnull NSNumber *)reactTag
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
        if (list == nil || list.count == 0) {
          reject(@"E_SNAP_MULTI", @"多机位离屏截图失败（场景或相机未就绪）", nil);
          return;
        }

        // 写文件放到后台，避免阻塞 UI 线程
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:list.count];
          NSString *tmpDir = NSTemporaryDirectory();
          long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);

          for (NSUInteger i = 0; i < list.count; i++) {
            NSString *b64 = list[i];
            if (b64 == nil || b64.length == 0) {
              continue;
            }

            NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            if (data == nil || data.length == 0) {
              continue;
            }

            NSString *filename = [NSString stringWithFormat:@"glb_snap_%lld_%lu.jpg", ts, (unsigned long)i];
            NSString *fullPath = [tmpDir stringByAppendingPathComponent:filename];
            NSError *err = nil;
            BOOL ok = [data writeToFile:fullPath options:NSDataWritingAtomic error:&err];
            if (!ok) {
              reject(@"E_WRITE_FILE", err.localizedDescription ?: @"写入截图文件失败", err);
              return;
            }
            [paths addObject:fullPath];
          }

          if (paths.count == 0) {
            reject(@"E_WRITE_FILE", @"未能生成任何截图文件（base64 解码失败）", nil);
            return;
          }

          resolve(paths);
        });
      }];
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

@end
