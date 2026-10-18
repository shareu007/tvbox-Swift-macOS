#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One embedded Node engine per app process. Provider code runs in V8 workers.
@interface TVBoxNodeRuntime : NSObject
+ (void)startWithScript:(NSString *)script
       assetsDirectory:(NSString *)assetsDirectory
      runtimeDirectory:(NSString *)directory
         configuration:(NSString *)configuration
    NS_SWIFT_NAME(start(script:assetsDirectory:runtimeDirectory:configuration:));
+ (nullable NSString *)listeningURL;
+ (nullable NSString *)startupError;
@end

NS_ASSUME_NONNULL_END
