#import <AppKit/AppKit.h>
#include <node_api.h>
#include <cstring>

static napi_value configure(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void *bytes = nullptr;
    size_t length = 0;
    if (argc != 1 || napi_get_buffer_info(env, args[0], &bytes, &length) != napi_ok ||
        !bytes || length < sizeof(void *)) {
        napi_throw_error(env, nullptr, "Expected the Electron native window handle");
        return nullptr;
    }
    void *handle = nullptr;
    std::memcpy(&handle, bytes, sizeof(handle));
    NSView *view = (__bridge NSView *)handle;
    if (![view isKindOfClass:[NSView class]] || !view.window) {
        napi_throw_error(env, nullptr, "Electron content view has no AppKit window");
        return nullptr;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSWindow *window = view.window;
    window.level = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1;
    window.ignoresMouseEvents = YES;
    window.hidesOnDeactivate = NO;
    window.excludedFromWindowsMenu = YES;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    [window orderBack:nil];
    napi_value result;
    napi_create_int64(env, window.windowNumber, &result);
    return result;
}

static napi_value initialize(napi_env env, napi_value exports) {
    napi_value function;
    napi_create_function(env, "configure", NAPI_AUTO_LENGTH, configure, nullptr, &function);
    napi_set_named_property(env, exports, "configure", function);
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, initialize)
