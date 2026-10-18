#import "TVBoxNodeRuntime.h"
#import <NodeMobile/NodeMobile.h>
#include "NodeAPI/node_api.h"
#include <unistd.h>

static NSThread *engineThread;
static NSString *configurationJSON;
static NSString *listeningURL;
static NSString *startupError;

static napi_value configuration(napi_env env, napi_callback_info info) {
    @synchronized (TVBoxNodeRuntime.class) {
        napi_value value;
        const char *json = configurationJSON.UTF8String ?: "{}";
        napi_create_string_utf8(env, json, NAPI_AUTO_LENGTH, &value);
        return value;
    }
}

static NSString *stringArgument(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value argument;
    if (napi_get_cb_info(env, info, &count, &argument, NULL, NULL) != napi_ok || count != 1) return nil;
    size_t length = 0;
    if (napi_get_value_string_utf8(env, argument, NULL, 0, &length) != napi_ok || length > 4096) return nil;
    char *buffer = calloc(length + 1, 1);
    if (!buffer) return nil;
    napi_get_value_string_utf8(env, argument, buffer, length + 1, &length);
    NSString *result = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    free(buffer);
    return result;
}

static napi_value ready(napi_env env, napi_callback_info info) {
    NSString *url = stringArgument(env, info);
    NSURLComponents *components = [NSURLComponents componentsWithString:url ?: @""];
    if ([components.scheme isEqualToString:@"http"] &&
        [components.host isEqualToString:@"127.0.0.1"] && components.port.integerValue > 0) {
        @synchronized (TVBoxNodeRuntime.class) { listeningURL = [url copy]; }
    }
    return NULL;
}

static napi_value failed(napi_env env, napi_callback_info info) {
    // Do not forward provider URLs, credentials or arbitrary exception text.
    @synchronized (TVBoxNodeRuntime.class) { startupError = @"手机内置脚本引擎启动失败，请重新启动 App"; }
    return NULL;
}

static napi_value initializeBridge(napi_env env, napi_value exports) {
    // Linked bindings are registered process-wide. Only the trusted engine
    // thread may access configuration; third-party provider workers cannot.
    if (NSThread.currentThread != engineThread) {
        napi_throw_error(env, "BRIDGE_ACCESS_DENIED", "Native bridge is unavailable to provider workers");
        return NULL;
    }
    napi_property_descriptor methods[] = {
        { "configuration", NULL, configuration, NULL, NULL, NULL, napi_default, NULL },
        { "ready", NULL, ready, NULL, NULL, NULL, napi_default, NULL },
        { "failed", NULL, failed, NULL, NULL, NULL, napi_default, NULL }
    };
    napi_define_properties(env, exports, 3, methods);
    return exports;
}

@implementation TVBoxNodeRuntime

+ (void)startWithScript:(NSString *)script assetsDirectory:(NSString *)assetsDirectory runtimeDirectory:(NSString *)directory configuration:(NSString *)configuration {
    @synchronized (self) {
        configurationJSON = [configuration copy];
        if (engineThread) return;
        // kLinked (0x02) makes this built-in binding available without loading
        // native addons from disk. The stable N-API avoids a V8 C++ ABI dependency.
        static napi_module bridge = { NAPI_MODULE_VERSION, 0x02, NULL, initializeBridge, "tvbox_mobile", NULL, { NULL } };
        napi_module_register(&bridge);
        NSArray<NSString *> *arguments = @[
            @"node", @"--permission", @"--allow-worker", @"--allow-addons", @"--max-old-space-size=128",
            [@"--allow-fs-read=" stringByAppendingString:script.stringByDeletingLastPathComponent],
            [@"--allow-fs-read=" stringByAppendingString:assetsDirectory],
            [@"--allow-fs-read=" stringByAppendingString:directory],
            [@"--allow-fs-write=" stringByAppendingString:directory], script
        ];
        engineThread = [[NSThread alloc] initWithBlock:^{
            @autoreleasepool {
                // Node implicitly permits reads under its initial cwd, even
                // for worker environments. iOS normally starts at "/". Scope
                // that implicit grant to disposable runtime data before boot.
                if (chdir(directory.fileSystemRepresentation) != 0) {
                    @synchronized (self) { startupError = @"无法创建手机脚本运行目录"; }
                    return;
                }
                // libuv requires argv strings in one contiguous allocation.
                NSUInteger bytes = 0;
                for (NSString *argument in arguments) bytes += [argument lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
                char *storage = calloc(bytes, 1);
                char **argv = calloc(arguments.count + 1, sizeof(char *));
                if (!storage || !argv) {
                    free(storage); free(argv);
                    @synchronized (self) { startupError = @"手机内置脚本引擎内存不足"; }
                    return;
                }
                char *cursor = storage;
                for (NSUInteger index = 0; index < arguments.count; index++) {
                    argv[index] = cursor;
                    strcpy(cursor, arguments[index].UTF8String);
                    cursor += strlen(cursor) + 1;
                }
                node_start((int)arguments.count, argv);
                free(argv); free(storage);
                @synchronized (self) {
                    listeningURL = nil;
                    startupError = @"手机内置脚本引擎已停止，请重新启动 App";
                }
            }
        }];
        engineThread.name = @"TVBox Mobile Spider";
        engineThread.stackSize = 4 * 1024 * 1024;
        [engineThread start];
    }
}

+ (NSString *)listeningURL { @synchronized (self) { return listeningURL; } }
+ (NSString *)startupError { @synchronized (self) { return startupError; } }
@end
