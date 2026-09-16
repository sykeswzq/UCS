// HealthBoost - iOS App that writes steps / distance / flights to Apple Health as device source
// 使用 com.apple.private.healthkit.source_override + authorization_bypass 私有权限
// 让写出的 step count 来源伪装成 iPhone 设备源，从而被微信运动等应用读取
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <HealthKit/HealthKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <UserNotifications/UserNotifications.h>

// 前向声明：HBDumpEntitlements 定义在 HBLog 之前，需先声明否则会触发隐式声明错误
static void HBLog(NSString *fmt, ...);

static NSString * const HBSettingsKey = @"com.sykes.ucs.settings";

// MARK: - Logging helper
// 日志同时写到两个位置：
//   1) /var/mobile/Media/HealthBoost/hb_log.txt  —— Files App「我的 iPhone」里能直接看到
//   2) App 沙盒 Documents/hb_log.txt              —— 保底，App 内「查看日志」能读
// App 带 com.apple.private.security.no-sandbox，可写沙盒外路径。

// 追加一行到指定路径，并自动裁剪为滚动日志（最多保留 HB_MAX_LOG_LINES 行）
// 防止日志无限增长导致 UIPasteboard 复制失败 / 弹窗截断。
static const NSInteger HB_MAX_LOG_LINES = 200;

static void HBAppendLine(NSString *path, NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // 读取旧日志
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *lines = [NSMutableArray array];
    if (old.length > 0) {
        [lines addObjectsFromArray:[old componentsSeparatedByString:@"\n"]];
        // 去掉末尾可能存在的空行
        while (lines.count > 0 && [lines.lastObject length] == 0) {
            [lines removeLastObject];
        }
    }

    // 追加新行
    [lines addObject:line];

    // 滚动裁剪：保留最后 HB_MAX_LOG_LINES 行
    while (lines.count > HB_MAX_LOG_LINES) {
        [lines removeObjectAtIndex:0];
    }

    // 写回
    NSString *out = [lines componentsJoinedByString:@"\n"];
    if (lines.count > 0) out = [out stringByAppendingString:@"\n"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 外部共享日志路径（Files App 可见）
static NSString *HBSharedLogPath(void) {
    return @"/var/mobile/Media/HealthBoost/hb_log.txt";
}

// API 探测输出路径：把 HealthKit 相关类的全部方法（含私有）导出到这里，
// 用于定位真正能改写 sample 来源的私有初始化器 / 保存入口。
static NSString *HBAPIDumpPath(void) {
    return @"/var/mobile/Media/HealthBoost/api_dump.txt";
}

// 枚举某个类的所有实例方法（含私有），追加到 out
static void HBDumpMethods(NSMutableString *out, Class cls, NSString *clsName, NSArray *keywords) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        if (name == NULL) continue;
        NSString *sn = [NSString stringWithUTF8String:name];
        // 若给了关键字，只输出命中的；否则全输出
        BOOL hit = (keywords == nil);
        for (NSString *kw in keywords) {
            if ([sn rangeOfString:kw options:NSCaseInsensitiveSearch].length > 0) { hit = YES; break; }
        }
        if (hit) {
            // 附带参数个数与方法签名，便于安全构造 NSInvocation
            unsigned int nargs = method_getNumberOfArguments(methods[i]);
            const char *types = method_getTypeEncoding(methods[i]);
            [out appendFormat:@"%@ : %@   [args=%u types=%s]\n",
             clsName, sn, nargs, types ? types : ""];
        }
    }
    free(methods);
}

// 把步数写到「供微信 tweak 读取」的通道。
// 双通道（v76 起）：
//   1) 文件 /var/mobile/Media/HealthBoost/hb_steps.txt —— 真实共享路径，roothide 下最稳，
//      微信进程里的 tweak 直接读这个文件。这是主通道。
//   2) CFPreferences com.apple.mobile.healthboost —— 兜底。
// 这一步与写 HealthKit 是两条独立链路：HealthKit 管「健康」App，这里管「微信运动」。
// 步数文件统一格式：第一行数字，第二行 date:YYYY-MM-DD（v1.0.201 起必带）。
// tweak 端据此做「今天」校验，昨天的残留值不再被微信读走。
static NSString *HBFakeDateLine(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"date:%@", [f stringFromDate:[NSDate date]]];
}

static void HBWriteStepsFile(long steps) {
    NSString *dir = @"/var/mobile/Media/HealthBoost";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *path = [dir stringByAppendingPathComponent:@"hb_steps.txt"];
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    BOOL ok = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    HBLog(@"[HealthBoost] 已写入步数文件 %ld (file=%d) @ %@", steps, ok, path);
}

// 找到微信相关进程的数据容器路径。
// 原理：微信是 App Store 应用，跑在沙盒里，**读不到** /var/mobile/Media/ 下的文件。
// 但本 App 带 no-sandbox 权限，可以直接把步数文件写进它们自己的容器，
// 各自进程对自己容器内的文件是必定可读的 —— 这是绕开沙盒最可靠的通道。
// iOS 在每个数据容器根目录放 .com.apple.mobile_container_manager.metadata.plist，
// 里面的 MCMMetadataIdentifier 就是该容器对应的 bundle id。
static NSArray<NSString *> *HBWeChatContainerPaths(void) {
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
    if (!dirs) {
        HBLog(@"[HealthBoost] 容器扫描失败: /var/mobile/Containers/Data/Application 不可读");
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *d in dirs) {
        NSString *meta = [base stringByAppendingFormat:@"/%@/.com.apple.mobile_container_manager.metadata.plist", d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"];
        // 主微信、步数进程 UGGD，以及所有微信插件/扩展容器都覆盖，
        // 避免因为猜错「到底哪个进程在读步数」而漏掉真正的目标。
        if ([ident isEqualToString:@"com.tencent.xin"] ||
            [ident isEqualToString:@"UGGD"] ||
            [ident hasPrefix:@"com.tencent"]) {
            [out addObject:[base stringByAppendingPathComponent:d]];
            HBLog(@"[HealthBoost] 找到微信相关容器: %@ -> %@", ident, d);
        }
    }
    return out;
}

// 无沙盒的守护进程（比如 UGGD）可能根本没有数据容器，
// 此时它的可写落点是 /var/mobile/Documents。这里一并写一份兜底。
static NSInteger HBWriteStepsToVarMobileDocuments(long steps) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *doc = @"/var/mobile/Documents";
    if (![fm fileExistsAtPath:doc]) {
        [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    if (ok) [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
    HBLog(@"[HealthBoost] 写入 /var/mobile/Documents/hb_steps.txt (ok=%d) —— 供无容器守护进程读取", ok);
    return ok ? 1 : 0;
}

// ②d roothide 修复：把步数写到 UCS App 自身容器 Documents。roothide 应用的自身容器
// 由系统重映射到 /var/roothide/var/mobile/Containers/.../Documents，与 tweak 端
// 枚举 com.sykes.ucs.app 容器读取的路径完全一致，是最稳的跨进程通道（不依赖 /var/mobile 重映射）。
static NSInteger HBWriteStepsToOwnContainer(long steps) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = paths.firstObject;
    if (doc.length == 0) return 0;
    NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    if (ok) [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
    HBLog(@"[HealthBoost] 写入自身容器步数文件 (ok=%d) @ %@", ok, path);
    return ok ? 1 : 0;
}

// 把步数写进微信自己的容器（沙盒内可读），这是 v78 的主通道。
static NSInteger HBWriteStepsToWeChatContainers(long steps) {
    NSArray *containers = HBWeChatContainerPaths();
    if (containers.count == 0) {
        HBLog(@"[HealthBoost] 警告: 未找到微信容器，步数无法传给微信（微信可能未安装）");
        return 0;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger okCount = 0;
    NSString *content = [NSString stringWithFormat:@"%ld\n%@\n", steps, HBFakeDateLine()];
    for (NSString *c in containers) {
        NSString *doc = [c stringByAppendingPathComponent:@"Documents"];
        if (![fm fileExistsAtPath:doc]) {
            [fm createDirectoryAtPath:doc withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *path = [doc stringByAppendingPathComponent:@"hb_steps.txt"];
        // v1.0.161：写之前先删旧文件，避免残留脏值（如早期测试写下的 99999）覆盖不彻底
        if ([fm fileExistsAtPath:path]) [fm removeItemAtPath:path error:nil];
        // 用 NSData 写并设 0644，确保微信进程（mobile 用户）可读
        BOOL ok = [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
        if (ok) {
            [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:path error:nil];
            okCount++;
        }
        HBLog(@"[HealthBoost] 写入容器步数 %ld -> %@ (ok=%d)", steps, path, ok);
    }
    return okCount;
}

static void HBWriteStepsPreference(long steps) {
    // v1.0.159：诊断增强——把"到底写了什么值到哪"打印出来，定位 99999 来源
    HBLog(@"[HealthBoost] >> 即将写入步数值 steps=%ld", steps);
    // 通道1（最可靠）：写进微信相关容器，沙盒内必定可读
    NSInteger nContainers = HBWriteStepsToWeChatContainers(steps);
    // 通道1b：无容器守护进程（UGGD）的兜底落点
    NSInteger nVarMobile = HBWriteStepsToVarMobileDocuments(steps);
    // 通道1c：roothide 修复 —— 写进 UCS App 自身容器（与 tweak ②c 读取对应）
    NSInteger nOwn = HBWriteStepsToOwnContainer(steps);
    // 通道2：共享 Media 目录（仅对无沙盒进程有效）
    HBWriteStepsFile(steps);
    // 通道3：CFPreferences 系统域（UCStep 同款跨沙盒手法）+ stepsDate 供 tweak 校验「今天」
    NSString *todayStr = HBFakeDateLine();   // 形如 date:2026-09-04
    CFPreferencesSetValue(CFSTR("steps"),
                          (__bridge CFNumberRef)@(steps),
                          CFSTR("com.apple.mobile.healthboost"),
                          kCFPreferencesAnyUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR("stepsDate"),
                          (__bridge CFStringRef)[todayStr substringFromIndex:5],
                          CFSTR("com.apple.mobile.healthboost"),
                          kCFPreferencesAnyUser,
                          kCFPreferencesAnyHost);
    BOOL ok = CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"),
                                       kCFPreferencesAnyUser,
                                       kCFPreferencesAnyHost);
    HBLog(@"[HealthBoost] 步数通道写入完成: 容器=%ld 自身容器=%ld varMobile=%ld Media=1 偏好sync=%d 写入值=%ld",
          (long)nContainers, (long)nOwn, (long)nVarMobile, ok, steps);
}

// 清除所有「供微信读取」的步数假数据，让微信恢复读取真实步数。
// 在用户关闭「每日自动生成」时调用：既然不再自动生成，就不应继续伪造。
static void HBClearStepsFiles(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *containers = HBWeChatContainerPaths();
    for (NSString *c in containers) {
        NSString *path = [c stringByAppendingPathComponent:@"Documents/hb_steps.txt"];
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:path error:nil];
            HBLog(@"[HealthBoost] 已清除容器步数文件: %@", path);
        }
    }
    NSString *varDoc = @"/var/mobile/Documents/hb_steps.txt";
    if ([fm fileExistsAtPath:varDoc]) { [fm removeItemAtPath:varDoc error:nil]; HBLog(@"[HealthBoost] 已清除 /var/mobile/Documents/hb_steps.txt"); }
    NSString *media = @"/var/mobile/Media/HealthBoost/hb_steps.txt";
    if ([fm fileExistsAtPath:media]) { [fm removeItemAtPath:media error:nil]; HBLog(@"[HealthBoost] 已清除 /var/mobile/Media/HealthBoost/hb_steps.txt"); }
    CFPreferencesSetValue(CFSTR("steps"), NULL, CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR("stepsDate"), NULL, CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.apple.mobile.healthboost"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    HBLog(@"[HealthBoost] 已清空 CFPreferences 步数，微信恢复真实步数");
}

// 扫描所有数据容器，收集 tweak 写下的诊断日志。
// tweak 跑在微信沙盒里，写不了 /var/mobile/Media/，只能写自己容器的 Documents。
// 本 App 无沙盒，可以遍历所有容器把它读回来。
static NSString *HBCollectTweakLogs(void) {
    NSMutableString *out = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) 共享位置（若 tweak 所在进程无沙盒，日志会在这里）
    NSString *shared = [NSString stringWithContentsOfFile:@"/var/mobile/Media/HealthBoost/tweak_log.txt"
                                                encoding:NSUTF8StringEncoding error:nil];
    if (shared.length > 0) {
        [out appendString:@"--- /var/mobile/Media/HealthBoost/tweak_log.txt ---\n"];
        [out appendString:shared];
        [out appendString:@"\n"];
    }

    // 2) 遍历所有数据容器的 Documents/hb_tweak_log.txt
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
    NSInteger found = 0;
    for (NSString *d in dirs) {
        NSString *meta = [base stringByAppendingFormat:@"/%@/.com.apple.mobile_container_manager.metadata.plist", d];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *ident = dict[@"MCMMetadataIdentifier"] ?: @"(unknown)";

        NSString *logPath = [base stringByAppendingFormat:@"/%@/Documents/hb_tweak_log.txt", d];
        NSString *c = [NSString stringWithContentsOfFile:logPath
                                              encoding:NSUTF8StringEncoding error:nil];
        if (c.length > 0) {
            found++;
            [out appendFormat:@"--- 容器日志 [%@] ---\n%@\n", ident, c];
        }
    }

    if (out.length == 0) {
        return @"（未找到任何 tweak 日志）\n"
               @"可能原因：\n"
               @"  1. tweak 未被注入 —— 装完 deb 后必须彻底杀掉微信再重开；\n"
               @"  2. 微信/UGGD 进程还没重启过；\n"
               @"  3. 注入器（ElleKit/Substrate）未加载本 tweak。\n";
    }
    if (found == 0 && shared.length > 0) found = 1;
    return out;
}

// 读取自身 entitlements 的实际生效值
// 目的：确认 ldid 签的 com.apple.private.healthkit.source_override 到底有没有被系统认可。
// 注意：SecTask 系列在 iOS SDK 中没有公开头文件（属 macOS 私有 API），
// 这里用 dlsym 运行时查找，找不到就跳过，避免编译/链接失败或运行时崩溃。
static void HBDumpEntitlements(void) {
    void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    if (!sec) {
        HBLog(@"[HealthBoost] ENT: Security.framework 加载失败");
        return;
    }

    typedef struct __SecTask *HBSecTaskRef;
    HBSecTaskRef (*hbSecTaskCreateFromSelf)(CFAllocatorRef) =
        (HBSecTaskRef (*)(CFAllocatorRef))dlsym(sec, "SecTaskCreateFromSelf");
    CFTypeRef (*hbSecTaskCopyValueForEntitlement)(HBSecTaskRef, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(HBSecTaskRef, CFStringRef, CFErrorRef *))dlsym(sec, "SecTaskCopyValueForEntitlement");

    if (!hbSecTaskCreateFromSelf || !hbSecTaskCopyValueForEntitlement) {
        HBLog(@"[HealthBoost] ENT: SecTask 符号不可用（iOS 未导出），跳过检查");
        return;
    }

    HBSecTaskRef task = hbSecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        HBLog(@"[HealthBoost] ENT: SecTaskCreateFromSelf 返回 NULL");
        return;
    }

    NSArray *keys = @[
        @"com.apple.private.healthkit.source_override",
        @"com.apple.private.healthkit.authorization_bypass",
        @"com.apple.private.healthkit.write_authorization_override",
        @"com.apple.private.security.storage.Health",
        @"com.apple.developer.healthkit",
        @"application-identifier",
    ];
    for (NSString *k in keys) {
        CFTypeRef v = hbSecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)k, NULL);
        if (v) {
            HBLog(@"[HealthBoost] ENT %@ = %@", k, (__bridge id)v);
            CFRelease(v);
        } else {
            HBLog(@"[HealthBoost] ENT %@ = (nil 未生效)", k);
        }
    }
    CFRelease(task);
}

// 导出 API 清单到共享目录（不受日志行数限制）
static void HBDumpHealthKitAPIs(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== HealthKit 私有 API 探测 ===\n\n"];

    // 只关心与「来源 / 初始化 / 保存」相关的方法，避免文件过大
    NSArray *kws = @[@"init", @"source", @"save", @"revision", @"device", @"insert", @"add", @"origin"];

    [out appendString:@"--- HKQuantitySample ---\n"];
    HBDumpMethods(out, [HKQuantitySample class], @"HKQuantitySample", kws);

    [out appendString:@"\n--- HKSample ---\n"];
    HBDumpMethods(out, [HKSample class], @"HKSample", kws);

    [out appendString:@"\n--- HKSourceRevision ---\n"];
    HBDumpMethods(out, [HKSourceRevision class], @"HKSourceRevision", nil);

    [out appendString:@"\n--- HKSource ---\n"];
    HBDumpMethods(out, [HKSource class], @"HKSource", nil);

    [out appendString:@"\n--- HKHealthStore (save/delete 相关) ---\n"];
    HBDumpMethods(out, [HKHealthStore class], @"HKHealthStore", @[@"save", @"delete", @"insert", @"add"]);

    [out appendString:@"\n--- HKQuantitySample 全部方法 ---\n"];
    HBDumpMethods(out, [HKQuantitySample class], @"HKQuantitySample", nil);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [HBAPIDumpPath() stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [out writeToFile:HBAPIDumpPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 沙盒内日志路径（保底）
static NSString *HBSandboxLogPath(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [doc stringByAppendingPathComponent:@"hb_log.txt"];
}

static void HBLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"%@", msg);

    NSDateFormatter *fmtDate = [[NSDateFormatter alloc] init];
    fmtDate.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmtDate stringFromDate:[NSDate date]], msg];

    HBAppendLine(HBSharedLogPath(), line);
    HBAppendLine(HBSandboxLogPath(), line);
}

// MARK: - Helper: create HKQuantitySample with device source via KVC

static HKQuantitySample *HBMakeDeviceSample(HKQuantityType *type,
                                           HKQuantity *quantity,
                                           NSDate *start,
                                           NSDate *end,
                                           HKSourceRevision *deviceSourceRev) {
    HKDevice *device = [HKDevice localDevice];
    HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:type
                                                              quantity:quantity
                                                           startDate:start
                                                             endDate:end
                                                               device:device
                                                           metadata:nil];
    if (!sample) return nil;
    // KVC 注入私有 ivar _sourceRevision，让 healthd 接受设备源
    if (deviceSourceRev) {
        @try {
            [sample setValue:[deviceSourceRev copy] forKey:@"_sourceRevision"];
        } @catch (NSException *e) {
            (void)e;
            // 回退：不注入 sourceRevision
        }
    }
    return sample;
}

// MARK: - Main View Controller (UCS：今日数据 / 操作 / 定时生成)

@interface HBMainViewController : UITableViewController <UNUserNotificationCenterDelegate>
@property (assign, nonatomic) long steps;
@property (assign, nonatomic) long flights;
@property (assign, nonatomic) double ratio;        // 步距系数 0.5~0.8，用于推算距离
@property (assign, nonatomic) BOOL enabled;
@property (assign, nonatomic) BOOL scheduleOn;
@property (assign, nonatomic) BOOL isCLI;
@property (assign, nonatomic) BOOL autoCatchUp;
@property (assign, nonatomic) NSInteger schedHour;
@property (assign, nonatomic) NSInteger schedMinute;
@property (assign, nonatomic) BOOL busy;
@property (strong, nonatomic) HKHealthStore *healthStore;
@property (strong, nonatomic) UILabel *statusLabel;
@property (strong, nonatomic) UIDatePicker *timePicker;
@end

@implementation HBMainViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"UCS";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 48)];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.numberOfLines = 0;
    self.tableView.tableFooterView = self.statusLabel;

    [self loadSettings];
    [self setupNotifications];
    if (self.scheduleOn) [self scheduleDailyNotification];

    // v1.0.201 补生成：通知横幅若没被点到（App 未运行/用户忽略），当天就不会生成，
    // 微信会一直显示昨天的残留值。现在 App 每次启动/回到前台都检查一次：
    // 「已开定时 + 今天没生成过 + 已过设定时间」就自动补生成，不依赖点横幅。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    // v3.3.8: 去掉前台打开App时的自动补生成，只保留 launchd CLI 模式自动生成
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureLaunchAgentLoaded];
    });

    HBLog(@"[UCS] App 启动");
}

// v3.3.8: App 回到前台只重新加载 LaunchAgent，不自动补生成
- (void)appWillEnterForeground {
    [self ensureLaunchAgentLoaded];
}

// v3.3.4: App 在 mobile 用户上下文运行，自己加载 LaunchAgent（postinst root 加载失败 exit=45）
- (void)ensureLaunchAgentLoaded {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSString *plist = @"/var/mobile/Library/LaunchAgents/com.sykes.ucs.schedule.plist";
        NSString *cmd = [NSString stringWithFormat:
            @"launchctl bootstrap user/foreground '%@' 2>&1; "
            @"launchctl enable user/foreground/com.sykes.ucs.schedule 2>&1; "
            @"launchctl kickstart user/foreground/com.sykes.ucs.schedule 2>&1", plist];
        int result = 0;
        typedef int (*system_fn)(const char *);
        system_fn system_ptr = (system_fn)dlsym(RTLD_DEFAULT, "system");
        if (system_ptr) {
            result = system_ptr([cmd UTF8String]);
        } else {
            HBLog(@"[UCS] system() not found");
        }
        HBLog(@"[UCS] load LaunchAgent result=%d", result);
    });
}

// 最后生成日期记录（App 沙盒 Documents/hb_lastgen.txt，内容为 YYYY-MM-DD）
static NSString *HBLastGenPath(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [doc stringByAppendingPathComponent:@"hb_lastgen.txt"];
}

static NSString *HBTodayString(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd";
    return [f stringFromDate:[NSDate date]];
}

- (void)checkAndCatchUpGeneration {
    HBLog(@"[UCS] checkAndCatchUp: scheduleOn=%d busy=%d", self.scheduleOn, self.busy);
    if (!self.scheduleOn || self.busy) {
        HBLog(@"[UCS] checkAndCatchUp: skip (scheduleOn/busy)");
        return;
    }
    NSString *last = [NSString stringWithContentsOfFile:HBLastGenPath() encoding:NSUTF8StringEncoding error:nil];
    last = [last stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    HBLog(@"[UCS] checkAndCatchUp: last=%@ today=%@", last, HBTodayString());
    if ([last isEqualToString:HBTodayString()]) {
        HBLog(@"[UCS] checkAndCatchUp: already generated today");
        return;
    }
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate date]];
    HBLog(@"[UCS] checkAndCatchUp: now=%02ld:%02ld sched=%02ld:%02ld", (long)now.hour, (long)now.minute, (long)self.schedHour, (long)self.schedMinute);
    if (now.hour < self.schedHour || (now.hour == self.schedHour && now.minute < self.schedMinute)) {
        HBLog(@"[UCS] checkAndCatchUp: not time yet");
        return;
    }
    [self loadSettings];   // 强制从磁盘刷新，避免用内存里的旧步数值
    HBLog(@"[UCS] 错过定时通知，自动补生成今日数据 (设定 %02ld:%02ld, 当前 %02ld:%02ld)",
          (long)self.schedHour, (long)self.schedMinute, (long)now.hour, (long)now.minute);
    self.autoCatchUp = YES;
    [self updateStatus:@"已自动补生成今日数据…"];
    [self generateNow];
}

// v1.0.205 修复「每次打开都弹授权框」：
// 问题根因：每次启动都调用 requestAuthorization，系统重复弹窗。
// 修复方案：用文件持久化标记（跨重启保留），仅首次请求授权。
static NSString * const HBNotifFailCountKey = @"hb_notif_fail_count";
static NSString * const HBNotifFlagFile = @"/var/mobile/Documents/.hb_notif_requested";

// 检查是否已请求过通知权限（文件持久化，比NSUserDefaults更可靠）
static BOOL HBHasRequestedNotification(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 先查文件（最可靠）
    if ([fm fileExistsAtPath:HBNotifFlagFile]) return YES;
    // 再查UserDefaults（辅助）
    BOOL defaultsVal = [[NSUserDefaults standardUserDefaults] boolForKey:HBNotifRequestedKey];
    return defaultsVal;
}

// 标记已请求通知权限（写文件 + UserDefaults双重保障）
static void HBMarkNotificationRequested(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 写标记文件到用户Documents（roothide下可写）
    [fm createFileAtPath:HBNotifFlagFile contents:nil attributes:nil];
    // 同步UserDefaults
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:HBNotifRequestedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString * const HBNotifRequestedKey = @"hb_notif_requested";
- (void)setupNotifications {
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    c.delegate = self;
    
    // 检查是否已经请求过授权（文件持久化，跨重启保留）
    if (HBHasRequestedNotification()) {
        HBLog(@"[UCS] 通知权限已请求过，跳过弹窗");
        return;
    }
    
    // 直接请求授权
    [c requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound|UNAuthorizationOptionBadge
                    completionHandler:^(BOOL g, NSError *e){
        // 标记已请求（无论成功失败）
        HBMarkNotificationRequested();
        
        if (g) {
            HBLog(@"[UCS] 通知授权成功");
            [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:HBNotifFailCountKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        } else {
            NSInteger failCount = [[NSUserDefaults standardUserDefaults] integerForKey:HBNotifFailCountKey] + 1;
            [[NSUserDefaults standardUserDefaults] setInteger:failCount forKey:HBNotifFailCountKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            HBLog(@"[UCS] 通知授权失败 attempt=%ld err=%@", (long)failCount, e ? e.localizedDescription : @"nil");
            // 失败超过3次，静默跳过
            if (failCount >= 3) {
                HBLog(@"[UCS] 通知授权连续失败3次，后续启动不再请求");
            }
        }
    }];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"今日数据";
    if (s == 1) return @"操作";
    return @"定时生成";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;
    if (s == 1) return 1;
    // 定时生成section：生成时间 + 设置时间
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.tintColor = [UIColor systemOrangeColor];

    if (ip.section == 0) {
        if (ip.row == 0) {
            cell.imageView.image = [UIImage systemImageNamed:@"figure.walk"];
            cell.textLabel.text = @"步数";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 步", self.steps];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            cell.imageView.image = [UIImage systemImageNamed:@"ruler"];
            cell.textLabel.text = @"距离";
            double km = self.steps * self.ratio / 1000.0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.3f 公里", km];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"stairs"];
            cell.textLabel.text = @"楼层";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 层", self.flights];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.section == 1) {
        cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
        cell.textLabel.text = @"生成运动数据";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.detailTextLabel.text = nil;
    } else {
        if (ip.row == 0) {
            cell.imageView.image = [UIImage systemImageNamed:@"clock"];
            cell.textLabel.text = @"每日自动生成";
            cell.detailTextLabel.text = nil;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = self.scheduleOn;
            [sw addTarget:self action:@selector(scheduleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (ip.row == 1) {
            cell.imageView.image = [UIImage systemImageNamed:@"timer"];
            cell.textLabel.text = @"生成时间";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)self.schedHour, (long)self.schedMinute];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 0) {
        [self editIntegerWithTitle:@"步数" message:@"设置虚拟步数（在真实步数上累加）" current:self.steps handler:^(long v){
            self.steps = v;
            [self saveSettings];
            // 仅保存设置，不自动写入微信通道（避免输入时立即触发）
            // 用户需点击「生成」按钮才会写入虚拟步数到微信
            [self updateStatus:[NSString stringWithFormat:@"已设置：虚拟步数增量 %ld（点击「生成」按钮生效）", v]];
            [self.tableView reloadData];
        }];
    } else if (ip.section == 0 && ip.row == 2) {
        [self editIntegerWithTitle:@"楼层" message:@"设置爬楼层数" current:self.flights handler:^(long v){ self.flights = v; [self saveSettings]; [self.tableView reloadData]; }];
    } else if (ip.section == 1) {
        [self generateNow];
    } else if (ip.section == 2 && ip.row == 1) {
        [self pickTime];
    }
}

- (void)editIntegerWithTitle:(NSString *)title message:(NSString *)message current:(long)current handler:(void(^)(long))handler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf){
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", current];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){
        long v = [a.textFields.firstObject.text integerValue];
        if (v < 0) v = 0;
        handler(v);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// 系统原生时间选择器：模态 UINavigationController 内放 UIDatePicker(.wheels) + 完成/取消。
// 旧版用 ActionSheet + 手写约束，布局错乱导致「确定」点不动；原生导航栏按钮最稳。
- (void)pickTime {
    UIViewController *pickerVC = [[UIViewController alloc] init];
    pickerVC.view.backgroundColor = [UIColor systemBackgroundColor];
    pickerVC.title = @"选择生成时间";

    UIDatePicker *p = [[UIDatePicker alloc] init];
    p.datePickerMode = UIDatePickerModeTime;
    p.preferredDatePickerStyle = UIDatePickerStyleWheels;
    p.translatesAutoresizingMaskIntoConstraints = NO;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.hour = self.schedHour; c.minute = self.schedMinute;
    p.date = [cal dateFromComponents:c] ?: [NSDate date];
    [pickerVC.view addSubview:p];
    self.timePicker = p;
    [NSLayoutConstraint activateConstraints:@[
        [p.leadingAnchor constraintEqualToAnchor:pickerVC.view.leadingAnchor],
        [p.trailingAnchor constraintEqualToAnchor:pickerVC.view.trailingAnchor],
        [p.centerYAnchor constraintEqualToAnchor:pickerVC.view.centerYAnchor],
        [p.heightAnchor constraintEqualToConstant:216]
    ]];

    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                            style:UIBarButtonItemStyleDone
                                                           target:self
                                                           action:@selector(pickTimeDone:)];
    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(dismissPicker)];
    pickerVC.navigationItem.rightBarButtonItem = done;
    pickerVC.navigationItem.leftBarButtonItem = cancel;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pickerVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)pickTimeDone:(id)sender {
    UIDatePicker *p = self.timePicker;
    if (p) {
        NSCalendar *c2 = [NSCalendar currentCalendar];
        NSDateComponents *cc = [c2 components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:p.date];
        self.schedHour = cc.hour; self.schedMinute = cc.minute;
        [self saveSettings];
        [self scheduleDailyNotification];
        [self.tableView reloadData];
        // v3.2.4: 如果新设定时间在当前时间之后，删掉"今天已生成"标记，
        // 这样到新时间会自动触发一次（不用手动删 hb_lastgen.txt）。
        NSDateComponents *now = [c2 components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate date]];
        BOOL futureTime = (cc.hour > now.hour) || (cc.hour == now.hour && cc.minute > now.minute);
        if (futureTime) {
            [[NSFileManager defaultManager] removeItemAtPath:HBLastGenPath() error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Documents/hb_lastgen.txt" error:nil];
        }
        [self updateStatus:[NSString stringWithFormat:@"已设置每日 %02ld:%02ld 生成", (long)self.schedHour, (long)self.schedMinute]];
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dismissPicker {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)scheduleSwitchChanged:(UISwitch *)sender {
    self.scheduleOn = sender.isOn;
    [self saveSettings];
    if (self.scheduleOn) [self scheduleDailyNotification];
    else {
        [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"UCSDailyGen"]];
        HBClearStepsFiles();   // 关闭定时：清掉微信的假步数，恢复真实
    }
    [self updateStatus:self.scheduleOn ? [NSString stringWithFormat:@"已开启每日 %02ld:%02ld 定时生成", (long)self.schedHour, (long)self.schedMinute] : @"已关闭定时"];
}

- (void)scheduleDailyNotification {
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c removePendingNotificationRequestsWithIdentifiers:@[@"UCSDailyGen"]];
    if (!self.scheduleOn) return;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"UCS";
    content.body = @"正在生成今日运动数据…";
    NSDateComponents *trig = [[NSDateComponents alloc] init];
    trig.hour = self.schedHour; trig.minute = self.schedMinute;
    UNCalendarNotificationTrigger *t = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:trig repeats:YES];
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"UCSDailyGen" content:content trigger:t];
    [c addNotificationRequest:req withCompletionHandler:nil];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    if ([notification.request.identifier isEqualToString:@"UCSDailyGen"]) {
        [self loadSettings];   // v1.0.201：App 挂起恢复时 viewDidLoad 不会重跑，先刷新磁盘设置
        [self generateNow];
    }
    completionHandler(UNNotificationPresentationOptionNone);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void(^)(void))completionHandler {
    if ([response.notification.request.identifier isEqualToString:@"UCSDailyGen"]) {
        [self loadSettings];
        [self generateNow];
    }
    completionHandler();
}

#pragma mark - Settings

- (void)loadSettings {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:HBSettingsKey];
    if (!d) d = @{@"enabled":@YES, @"steps":@1000, @"ratio":@0.7, @"flights":@5, @"scheduleOn":@NO, @"hour":@9, @"minute":@0};
    self.enabled = [d[@"enabled"] boolValue];
    self.steps = [d[@"steps"] longValue]; if (self.steps <= 0) self.steps = 1000;
    self.ratio = [d[@"ratio"] doubleValue]; if (self.ratio<0.5) self.ratio=0.5; if (self.ratio>0.8) self.ratio=0.8;
    self.flights = [d[@"flights"] longValue]; if (self.flights <= 0) self.flights = 5;
    self.scheduleOn = [d[@"scheduleOn"] boolValue];
    self.schedHour = [d[@"hour"] integerValue]; if (self.schedHour<0||self.schedHour>23) self.schedHour=9;
    self.schedMinute = [d[@"minute"] integerValue]; if (self.schedMinute<0||self.schedMinute>59) self.schedMinute=0;
    [self updateStatus:self.scheduleOn ? [NSString stringWithFormat:@"已就绪 · 每日 %02ld:%02ld 定时生成", (long)self.schedHour, (long)self.schedMinute] : @"已就绪"];
}

- (void)saveSettings {
    NSDictionary *d = @{@"enabled":@(self.enabled), @"steps":@(self.steps), @"ratio":@(self.ratio), @"flights":@(self.flights), @"scheduleOn":@(self.scheduleOn), @"hour":@(self.schedHour), @"minute":@(self.schedMinute)};
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:d forKey:HBSettingsKey];
    [ud synchronize];
    // v3.0.9: 同步写一份到共享路径，供 launchd CLI 守护进程读取（root 用户读不到 App 沙盒）
    [d writeToFile:@"/var/mobile/Documents/hb_schedule.plist" atomically:YES];
}

- (void)updateStatus:(NSString *)text { self.statusLabel.text = text; }
- (void)dismissKeyboard {}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Generation

- (void)generateNow {
    if (self.busy) return;
    long steps = self.steps; if (steps < 0) steps = 0;
    double distanceMeters = steps * self.ratio;
    long flights = self.flights; if (flights < 0) flights = 0;
    [self saveSettings];
    HBWriteStepsPreference(steps);

    if (![HKHealthStore isHealthDataAvailable]) {
        [self updateStatus:@"此设备不支持健康数据"];
        [self showAlert:@"不支持" message:@"当前设备不可用 Apple Health"];
        return;
    }
    self.busy = YES;
    [self updateStatus:@"正在生成运动数据..."];
    if (!self.healthStore) self.healthStore = [[HKHealthStore alloc] init];
    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
    NSSet *shareTypes = [NSSet setWithObjects:stepType, distType, flightType, nil];
    if (self.isCLI) {
        // CLI mode: already authorized from UI use, skip request dialog
        [self fetchDeviceSourceRevision:^(HKSourceRevision *devRev) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self writeSamplesSequentially:devRev stepCount:steps distanceM:distanceMeters flights:flights];
            });
        }];
        return;
    }
    [self.healthStore requestAuthorizationToShareTypes:shareTypes readTypes:nil completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                self.busy = NO;
                [self updateStatus:@"健康授权失败"];
                [self showAlert:@"授权失败" message:error ? error.localizedDescription : @"授权失败"];
                return;
            }
            [self updateStatus:@"正在写入健康数据..."];
            [self fetchDeviceSourceRevision:^(HKSourceRevision *devRev) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self writeSamplesSequentially:devRev stepCount:steps distanceM:distanceMeters flights:flights];
                });
            }];
        });
    }];
}

- (void)fetchDeviceSourceRevision:(void(^)(HKSourceRevision *))completion {
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.day = -7;
    NSDate *start = [cal dateByAddingComponents:comps toDate:now options:0];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:start endDate:now options:HKQueryOptionNone];
    HKSampleQuery *q = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                       predicate:pred
                                                           limit:200
                                                 sortDescriptors:nil
                                                  resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        if (error) { HBLog(@"[UCS] fetchDeviceSource error: %@", error); }
        HKSourceRevision *found = nil;
        NSArray *samples = results ?: @[];
        for (HKSample *s in samples) {
            HKSourceRevision *r = s.sourceRevision;
            if (!r) continue;
            HKSource *src = r.source;
            NSString *bid = src ? src.bundleIdentifier : nil;
            HBLog(@"[UCS] sample source: bid=%@", bid ?: @"nil");
            if (bid == nil) { found = r; break; }
            if ([bid hasPrefix:@"com.apple.health."] && !found) { found = r; }
        }
        HBLog(@"[UCS] found deviceSourceRev: %@", found ?: @"nil");
        if (completion) completion(found);
    }];
    [self.healthStore executeQuery:q];
}

- (void)writeSamplesSequentially:(HKSourceRevision *)deviceRev
                       stepCount:(long)steps
                     distanceM:(double)distanceMeters
                        flights:(long)flights {
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *startOfDay = [cal startOfDayForDate:now];

    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];

    // UCS v3.0.5：endDate 不能是 now。新合成样本铺在"未来 now+N*60"，若查询 endDate=now，
    // 未来样本落在窗口外，下次生成时查不到旧虚拟样本、删不掉，导致累加。endDate 给到 48 小时后。
    NSDate *endOfWindow = [startOfDay dateByAddingTimeInterval:86400.0 * 2];
    NSPredicate *todayPred = [HKQuery predicateForSamplesWithStartDate:startOfDay
                                                              endDate:endOfWindow
                                                            options:HKQueryOptionNone];
    HKSampleQuery *query = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                          predicate:todayPred
                                                              limit:HKObjectQueryNoLimit
                                                    sortDescriptors:nil
                                                     resultsHandler:^(HKSampleQuery *q, NSArray<__kindof HKSample *> *results, NSError *error) {
        if (error) {
            HBLog(@"[UCS] query error: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error busy:YES]; });
            return;
        }
        NSArray *samples = results ?: @[];
        HBLog(@"[UCS] today %lu samples", (unsigned long)samples.count);

        // UCS v3.0 重构：显示步数 = 当天真实步数 + 虚拟步数（用户设定的绝对值，替换式）。
        // 旧 v2.0.1 在此检测到"已有真实设备步数"就早退、不写虚拟样本，导致健康 App 只显示真实步数、
        // 而微信经 tweak 显示 真实+虚拟，两边对不上。现在无论当天是否已有真实步数，都继续走下方
        // 统一流程：删旧虚拟合成样本 -> 写距离/楼层 -> 写新虚拟样本。真实样本永不删除。
        HBLog(@"[UCS] 当天样本 %lu 条，统一走 真实+虚拟 流程", (unsigned long)samples.count);

        HKSource *defaultSource = [HKSource defaultSource];
        NSString *myBid = defaultSource.bundleIdentifier;
        HBLog(@"[UCS] defaultSource bid = %@", myBid ?: @"(nil)");

        NSMutableArray *deviceSamples = [NSMutableArray array];
        for (HKSample *s in samples) {
            HKSourceRevision *rev = s.sourceRevision;
            NSString *bid = rev.source.bundleIdentifier;
            BOOL isDevice = (bid == nil);
            BOOL isHealthApp = (bid != nil && [bid hasPrefix:@"com.apple.health."]);
            BOOL isMine = (myBid != nil && bid != nil && [bid isEqualToString:myBid]);
            if (isDevice || isHealthApp || isMine) [deviceSamples addObject:s];
        }
        __weak typeof(self) weakSelf = self;
        // 修复(V2.0.2)：绝不删除真实设备/健康样本，仅清掉本 App 之前写的合成样本
        // （HBSyntheticStepMetaKey 标记），避免真实步数被抹。原逻辑会 deleteObject 设备/健康源样本。
        NSMutableArray *oldSynthetic = [NSMutableArray array];
        for (HKSample *s in deviceSamples) {
            if ([s.metadata[HBSyntheticStepMetaKey] boolValue]) [oldSynthetic addObject:s];
        }
        HBLog(@"[UCS] deletable old synthetic samples: %lu (of %lu total today)",
              (unsigned long)oldSynthetic.count, (unsigned long)samples.count);
        void (^startWrite)(void) = ^{
            HBLog(@"[UCS] start writing: steps=%ld dist=%.1f flights=%ld", steps, distanceMeters, flights);
            [weakSelf _writeSteps:steps dist:distanceMeters flights:flights deviceRev:deviceRev index:0];
        };
        if (oldSynthetic.count > 0) {
            dispatch_group_t group = dispatch_group_create();
            for (HKSample *s in oldSynthetic) {
                dispatch_group_enter(group);
                [self.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e) {
                    HBLog(@"[UCS] delete synthetic %@: ok=%d", s.sampleType.identifier, ok);
                    dispatch_group_leave(group);
                }];
            }
            dispatch_group_notify(group, dispatch_get_main_queue(), startWrite);
        } else {
            HBLog(@"[UCS] no synthetic samples to delete");
            dispatch_async(dispatch_get_main_queue(), startWrite);
        }
    }];
    [self.healthStore executeQuery:query];
}

- (void)saveSamplePrivately:(HKQuantitySample *)sample completion:(void (^)(BOOL success, NSError *error))completion {
    SEL privSel = NSSelectorFromString(@"_saveObjects:atomically:skipInsertionFilter:completion:");
    Method m = privSel ? class_getInstanceMethod([HKHealthStore class], privSel) : NULL;
    unsigned int nargs = m ? method_getNumberOfArguments(m) : 0;
    HBLog(@"[UCS] _saveObjects 参数个数=%u (期望 6)", nargs);
    if (!m || nargs != 6) {
        HBLog(@"[UCS] 私有 save 不可用，退回公开 saveObject");
        [self.healthStore saveObject:sample withCompletion:completion];
        return;
    }
    @try {
        NSMethodSignature *sig = [self.healthStore methodSignatureForSelector:privSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:privSel];
        NSArray *objs = @[sample];
        BOOL atomically = YES;
        BOOL skipFilter = YES;
        void (^cb)(BOOL, NSError *) = [completion copy];
        [inv setArgument:&objs      atIndex:2];
        [inv setArgument:&atomically atIndex:3];
        [inv setArgument:&skipFilter atIndex:4];
        [inv setArgument:&cb        atIndex:5];
        [inv invokeWithTarget:self.healthStore];
        HBLog(@"[UCS] 已用私有 _saveObjects(skipInsertionFilter:YES) 提交");
    } @catch (NSException *e) {
        HBLog(@"[UCS] 私有 save 异常: %@ -> 退回公开 API", e);
        [self.healthStore saveObject:sample withCompletion:completion];
    }
}

- (void)verifyStepsWritten {
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSDate *now = [NSDate date];
    NSDate *startOfDay = [[NSCalendar currentCalendar] startOfDayForDate:now];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:now options:HKQueryOptionNone];
    HKStatisticsQuery *q = [[HKStatisticsQuery alloc] initWithQuantityType:stepType
                                                  quantitySamplePredicate:pred
                                                                  options:HKStatisticsOptionCumulativeSum
                                                        completionHandler:^(HKStatisticsQuery *query, HKStatistics *result, NSError *error) {
        if (error) { HBLog(@"[UCS] VERIFY error: %@", error); return; }
        HKQuantity *sum = [result sumQuantity];
        double v = sum ? [sum doubleValueForUnit:[HKUnit countUnit]] : 0;
        HBLog(@"[UCS] VERIFY 当天步数总和 = %.0f", v);
        HKSampleQuery *sq = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                            predicate:pred
                                                                limit:50
                                                      sortDescriptors:nil
                                                       resultsHandler:^(HKSampleQuery *q2, NSArray *results2, NSError *e2) {
            HBLog(@"[UCS] VERIFY 当天样本条数 = %lu", (unsigned long)(results2 ?: @[]).count);
            for (HKSample *s in (results2 ?: @[])) {
                NSString *bid = s.sourceRevision.source.bundleIdentifier;
                if ([s isKindOfClass:[HKQuantitySample class]]) {
                    HKQuantitySample *qs = (HKQuantitySample *)s;
                    double sv = [qs.quantity doubleValueForUnit:[HKUnit countUnit]];
                    HBLog(@"[UCS] VERIFY 样本: %.0f 步, 来源=%@", sv, bid ?: @"(nil=设备源)");
                }
            }
        }];
        [self.healthStore executeQuery:sq];
    }];
    [self.healthStore executeQuery:q];
}

// v2.0.x：把「虚拟步数增量」写成【合成步数样本】写进 Health，
// 使系统「健康」App 也显示 真实+虚拟（a = 真实设备步数 + 此增量）。
// 注意写的是【增量 v】，Health 会把真实步数与此增量求和得到 a；微信 tweak 已改直通，
// 直接读 Health 原值，不会双重加。每次先用 metadata 标识删掉旧合成样本再写新，
// 避免逐次设置累加。
// iOS 16.5 单条大样本被静默丢弃，改用每批 500 步分批写入。
static NSString *const HBSyntheticStepMetaKey = @"com.sykes.ucs.virtualStep";
static const long kSyntheticBatchSize = 500;  // 每批 500 步，减少去重风险
static const NSTimeInterval kBatchIntervalSeconds = 60;  // 每批时间窗口 60 秒

- (void)writeVirtualStepSample:(long)virtualSteps {
    if (![HKHealthStore isHealthDataAvailable]) { HBLog(@"[UCS] 不支持健康，跳过合成步数写入"); return; }
    if (!self.healthStore) self.healthStore = [[HKHealthStore alloc] init];
    __weak typeof(self) weakSelf = self;
    HKQuantityType *stepType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDate *startOfDay = [cal startOfDayForDate:now];
    // v3.0.5：同主流程，endDate 必须覆盖未来样本（铺在 now+N*60），否则删不掉
    NSDate *endOfWindow = [startOfDay dateByAddingTimeInterval:86400.0 * 2];
    NSPredicate *pred = [HKQuery predicateForSamplesWithStartDate:startOfDay endDate:endOfWindow options:HKQueryOptionNone];

    // 纯异步递归：第一步查询合成样本，完成后在后台队列处理
    HKSampleQuery *delQ = [[HKSampleQuery alloc] initWithSampleType:stepType
                                                          predicate:pred
                                                              limit:HKObjectQueryNoLimit
                                                    sortDescriptors:nil
                                                     resultsHandler:^(HKSampleQuery *q, NSArray *results, NSError *e) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableArray *syntheticSamples = [NSMutableArray array];
        NSMutableSet<NSNumber *> *occupiedMinute = [NSMutableSet set];
        for (HKSample *s in (results ?: @[])) {
            BOOL isSyn = [s.metadata[HBSyntheticStepMetaKey] boolValue];
            if (isSyn) { [syntheticSamples addObject:s]; continue; }
            NSInteger secs = (NSInteger)[s.startDate timeIntervalSinceDate:startOfDay];
            NSInteger minuteIdx = secs / 60;
            if (minuteIdx >= 0) [occupiedMinute addObject:@(minuteIdx)];
        }
        HBLog(@"[UCS] writeVirtual: found %lu synthetic, %lu occupied minutes",
              (unsigned long)syntheticSamples.count, (unsigned long)occupiedMinute.count);

        if (virtualSteps <= 0) {
            HBLog(@"[UCS] 虚拟步数=0，无样本需清理");
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (strongSelf2) [strongSelf2 finishWithError:nil busy:YES];
            });
            return;
        }

        // 在后台队列删除旧样本并写入新样本（纯异步递归，不阻塞任何队列）
        __block NSUInteger deleteIdx = 0;
        __block NSUInteger batchIdx = 0;
        __block long remaining = virtualSteps;
        __block NSError *finalError = nil;

        __block void (^processNextBatch)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;
            if (remaining <= 0 || batchIdx >= 70) {
                HBLog(@"[UCS] 合成步数分 %lu 批写入完毕，总量=%ld", (unsigned long)batchIdx, (long)virtualSteps);
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf3 = weakSelf;
                    if (strongSelf3) [strongSelf3 finishWithError:finalError busy:YES];
                });
                return;
            }

            long batch = (remaining < kSyntheticBatchSize) ? remaining : kSyntheticBatchSize;
            HKQuantity *qty = [HKQuantity quantityWithUnit:[HKUnit countUnit] doubleValue:(double)batch];
            // UCS v3.0.4：把合成样本铺在【未来时间】(now 之后)，每批间隔 kBatchIntervalSeconds。
            // 实测：
            //  - 铺"过去最近十几分钟"：和白天真实样本时间重叠，被 HKStatisticsQuery 去重，7000只算进~3660；
            //  - 铺"凌晨 startOfDay"：HealthKit 根本不计入(样本虽ok=1但健康总和=真实)；
            //  - 铺"未来 now+N*60"：不和任何已有样本重叠，且 HealthKit 正常计入(单批500实测生效)。
            // UCS v3.0.8: search empty minutes only in last 120 min. Going further back hits
            // pre-first-real-sample hours which HealthKit ignores (v3.0.3 lesson).
            NSInteger nowMinute = (NSInteger)[now timeIntervalSinceDate:startOfDay] / 60;
            NSInteger floorMin = nowMinute - 120; if (floorMin < 0) floorMin = 0;
            NSInteger chosenMin = nowMinute;
            BOOL found = NO;
            for (NSInteger m = nowMinute; m >= floorMin; m--) {
                if (![occupiedMinute containsObject:@(m)]) { chosenMin = m; found = YES; break; }
            }
            if (!found) chosenMin = nowMinute;  // busy window: lay on now, accept possible dedup
            [occupiedMinute addObject:@(chosenMin)];
            NSDate *batchStart = [startOfDay dateByAddingTimeInterval:(NSTimeInterval)(chosenMin * 60)];
            NSDate *batchEnd = [batchStart dateByAddingTimeInterval:kBatchIntervalSeconds];

            HKQuantitySample *sample = [HKQuantitySample quantitySampleWithType:stepType
                                                                      quantity:qty
                                                                   startDate:batchStart
                                                                     endDate:batchEnd
                                                                       device:[HKDevice localDevice]
                                                                     metadata:@{HBSyntheticStepMetaKey: @YES}];

            [strongSelf2 saveSamplePrivately:sample completion:^(BOOL ok, NSError *e){
                __strong typeof(weakSelf) strongSelf3 = weakSelf;
                if (!strongSelf3) return;
                if (!ok) {
                    HBLog(@"[UCS] 写入合成步数批次[%lu] 失败 err=%@", (unsigned long)batchIdx, e);
                    finalError = e;
                } else {
                    HBLog(@"[UCS] 写入合成步数批次[%lu] 步数=%ld ok=1", (unsigned long)batchIdx, (long)batch);
                }
                remaining -= batch;
                batchIdx++;
                // 异步递归：下一批在后台队列执行
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), processNextBatch);
            }];
        };

        __block void (^deleteNext)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;
            if (deleteIdx >= syntheticSamples.count) {
                // 删除完成，开始写入
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), processNextBatch);
                return;
            }
            HKSample *s = syntheticSamples[deleteIdx];
            [strongSelf2.healthStore deleteObject:s withCompletion:^(BOOL ok, NSError *e2){
                __strong typeof(weakSelf) strongSelf3 = weakSelf;
                if (!strongSelf3) return;
                HBLog(@"[UCS] 删除旧合成步数样本[%lu] ok=%d", (unsigned long)deleteIdx, ok);
                deleteIdx++;
                // 异步递归删除下一批
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), deleteNext);
            }];
        };

        deleteNext();
    }];
    [weakSelf.healthStore executeQuery:delQ];
}

- (void)_writeSteps:(long)steps dist:(double)distM flights:(long)flights deviceRev:(HKSourceRevision *)deviceRev index:(NSUInteger)index {
    // 步数改由 writeVirtualStepSample 以【合成样本(虚拟增量)】写入 Health，
    // 这里不再写设备步数样本，避免与真实设备步数及合成样本重复/双重叠加。
    if (index == 0) {
        [self _writeSteps:steps dist:distM flights:flights deviceRev:deviceRev index:1];
        return;
    }
    HKQuantityType *stepType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierStepCount];
    HKQuantityType *distType   = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierDistanceWalkingRunning];
    HKQuantityType *flightType = [HKQuantityType quantityTypeForIdentifier:HKQuantityTypeIdentifierFlightsClimbed];
    HKQuantityType *type;
    double value;
    if (index == 0)      { type = stepType;    value = (double)steps; }
    else if (index == 1) { type = distType;    value = distM; }
    else                 { type = flightType;  value = (double)flights; }
    NSDate *sampleNow = [NSDate date];
    HKUnit *unit = [HKUnit countUnit];
    if (type == distType) unit = [HKUnit meterUnit];
    HKQuantity *q = [HKQuantity quantityWithUnit:unit doubleValue:value];
    HKQuantitySample *sample = HBMakeDeviceSample(type, q, sampleNow, sampleNow, deviceRev);
    if (!sample) {
        HBLog(@"[UCS] sample creation failed");
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:nil busy:YES]; });
        return;
    }
    HBLog(@"[UCS] saving %@ value=%.2f", type.identifier, value);
    [self saveSamplePrivately:sample completion:^(BOOL success, NSError *error) {
        HBLog(@"[UCS] save %@: ok=%d err=%@", type.identifier, success, error ?: @"nil");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithError:error busy:YES]; });
            return;
        }
        if (index < 2) {
            [self _writeSteps:steps dist:distM flights:flights deviceRev:deviceRev index:index + 1];
        } else {
            HBLog(@"[UCS] all writes complete");
            [self writeVirtualStepSample:steps];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishSuccess:deviceRev];
                [self verifyStepsWritten];
            });
        }
    }];
}

// 生成完成后杀掉微信进程：tweak 注入在微信进程内，微信不主动重读步数时
// 光写 HealthKit 不会让微信运动立刻刷新。杀掉后下次打开微信会重新注入、
// 重新读 CMPedometer/HealthKit，立即显示 真实+虚拟。
// iOS SDK 禁用 system()，roothide 下 killall 路径也不固定。
// 直接用 sysctl 枚举进程表 + kill(PID, SIGKILL)，不依赖任何外部二进制。
#include <sys/sysctl.h>
#include <spawn.h>
#include <signal.h>
static void HBKillProcessNamed(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t needed = 0;
    if (sysctl(mib, 4, NULL, &needed, NULL, 0) < 0) return;
    struct kinfo_proc *procList = malloc(needed);
    if (!procList) return;
    if (sysctl(mib, 4, procList, &needed, NULL, 0) < 0) { free(procList); return; }
    int count = (int)(needed / sizeof(struct kinfo_proc));
    int killed = 0;
    for (int i = 0; i < count; i++) {
        char pcomm[256] = {0};
        strncpy(pcomm, procList[i].kp_proc.p_comm, sizeof(pcomm) - 1);
        if (strstr(pcomm, name) != NULL) {
            pid_t pid = procList[i].kp_proc.p_pid;
            if (pid > 1) {
                kill(pid, SIGKILL);
                HBLog(@"[UCS] killed %s (pid=%d)", pcomm, (int)pid);
                killed++;
            }
        }
    }
    free(procList);
    if (killed == 0) HBLog(@"[UCS] 未找到进程 %s（微信可能未在运行）", name);
}
static void HBKillWeChat(void) {
    HBKillProcessNamed("WeChat");
    HBKillProcessNamed("UGGD");
}

// v3.2.3: 不自动拉起微信。kill 微信让它下次打开时重新读 HealthKit，
// openURL weixin:// 会导致刚被 kill 的微信闪退。
static void HBLaunchWeChat(void) {
    HBLog(@"[UCS] skip launching WeChat (will sync on next open)");
}

- (void)finishSuccess:(HKSourceRevision *)deviceRev {
    self.busy = NO;
    [HBTodayString() writeToFile:HBLastGenPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [HBTodayString() writeToFile:@"/var/mobile/Documents/hb_lastgen.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self updateStatus:@"运动数据已生成，正在重启微信以刷新步数…"];
    HBKillWeChat();
    sleep(2);
    HBLaunchWeChat();
    if (self.isCLI) { NSLog(@"[UCS] done, exit"); exit(0); }
    // v3.2.5: autoCatchUp 时不 exit，留在前台显示结果，用户手动关 App
}

- (void)finishWithError:(NSError *)error busy:(BOOL)busyFlag {
    (void)busyFlag;
    self.busy = NO;
    if (error) {
        [self updateStatus:@"写入失败"];
        if (self.isCLI) { NSLog(@"[UCS] CLI error: %@", error); exit(1); }
        [self showAlert:@"写入失败" message:error.localizedDescription];
    } else {
        [self finishSuccess:nil];
    }
}

@end

// MARK: - App Delegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[HBMainViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--auto-generate") == 0) {
            NSLog(@"[UCS] CLI auto-generate mode");
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Documents/hb_schedule.plist"];
            if (![[cfg objectForKey:@"scheduleOn"] boolValue]) { NSLog(@"[UCS] schedule off, exit"); return 0; }
            NSDateFormatter *f = [[NSDateFormatter alloc] init]; f.dateFormat = @"yyyy-MM-dd";
            NSString *today = [f stringFromDate:[NSDate date]];
            NSString *last = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/hb_lastgen.txt" encoding:NSUTF8StringEncoding error:nil];
            if ([[last stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:today]) { NSLog(@"[UCS] already generated today, exit"); return 0; }
            NSInteger sh = [[cfg objectForKey:@"hour"] integerValue];
            NSInteger sm = [[cfg objectForKey:@"minute"] integerValue];
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDateComponents *nc = [cal components:NSCalendarUnitHour|NSCalendarUnitMinute fromDate:[NSDate date]];
            if (nc.hour < sh || (nc.hour == sh && nc.minute < sm)) { NSLog(@"[UCS] not time yet, exit"); return 0; }
            HBMainViewController *vc = [[HBMainViewController alloc] init];
            vc.isCLI = YES;
            [vc loadSettings];
            dispatch_async(dispatch_get_main_queue(), ^{
                [vc generateNow];
            });
            while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, TRUE) == kCFRunLoopRunTimedOut) {}
            return 0;
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
