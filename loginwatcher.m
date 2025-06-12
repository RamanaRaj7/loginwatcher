#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// Version information
#define LOGINWATCHER_VERSION "1.0.0"

// MARK: - Global State
BOOL isScreenLocked = NO;
BOOL isSystemAwake = YES;
NSTask *authMonitorProcess = nil;
NSFileHandle *outputHandle = nil;
NSPipe *logPipe = nil;
NSUInteger failedAuthCount = 0;      // Total failures across all methods
NSUInteger touchIDFailureCount = 0;  // TouchID-specific failures
NSUInteger passwordFailureCount = 0; // Password-specific failures

// Function prototypes
void executeLoginSuccessScript(NSString *method);
void executeLoginFailureScript(NSString *method);
void updateMonitoringState(void);
void startAuthMonitoring(void);
void stopAuthMonitoring(void);
BOOL checkIfScreenIsLocked(void);
void printVersion(void);
void printUsage(void);

// MARK: - Timestamp Formatter
NSString* getUTCTimestamp() {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    return [formatter stringFromDate:[NSDate date]];
}

// MARK: - Check if screen is locked using CoreGraphics
BOOL checkIfScreenIsLocked() {
    CFDictionaryRef sessionInfo = CGSessionCopyCurrentDictionary();
    BOOL isLocked = NO;
    
    if (sessionInfo) {
        // Check lock status directly from session dictionary
        id lockObj = (id)CFDictionaryGetValue(sessionInfo, CFSTR("CGSSessionScreenIsLocked"));
        id consoleObj = (id)CFDictionaryGetValue(sessionInfo, CFSTR("kCGSSessionOnConsoleKey"));
        
        if ((lockObj && [lockObj boolValue]) || (consoleObj && ![consoleObj boolValue])) {
            isLocked = YES;
        }
        
        CFRelease(sessionInfo);
    }
    
    return isLocked;
}

// MARK: - Script Execution (without logging script results)
void executeLoginSuccessScript(NSString *method) {
    NSString *homePath = NSHomeDirectory();
    NSString *scriptPath = [homePath stringByAppendingPathComponent:@".login_success"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:scriptPath]) {
        NSLog(@"SCRIPT | Success script not found | Path: %@", scriptPath);
        return; // Silently skip if script doesn't exist
    }
    
    // Check if file is executable
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:scriptPath error:nil];
    NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
    if (!([permissions unsignedShortValue] & 0100)) {
        NSLog(@"WARN   | Script not executable     | Path: %@", scriptPath);
        return;
    }
    
    // Execute with bash (no output logging)
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/bash"];
    [task setArguments:@[scriptPath, method]];
    
    // Set environment variables
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:getUTCTimestamp() forKey:@"AUTH_TIMESTAMP"];
    [env setObject:NSUserName() forKey:@"AUTH_USER"];
    [env setObject:@"SUCCESS" forKey:@"AUTH_RESULT"];
    [env setObject:method forKey:@"AUTH_METHOD"];
    [task setEnvironment:env];
    
    // Suppress output
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        NSLog(@"SCRIPT | Success script executed | ");
        // Don't wait for script to finish to avoid blocking
    } @catch (NSException *exception) {
        NSLog(@"ERROR  | Success script failed   |  Error: %@", [exception reason]);
    }
}

void executeLoginFailureScript(NSString *method) {
    // IMPORTANT: Use dispatch_after to introduce a small delay to check if the
    // screen is still locked before executing the failure script. This helps
    // avoid the race condition where unlock happens during auth failure processing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Check if Mac is already unlocked - if so, don't execute the failure script
        if (!isScreenLocked || !checkIfScreenIsLocked()) {
            NSLog(@"SCRIPT | Failure script skipped  | Mac is already unlocked");
            return;
        }
        
        NSString *homePath = NSHomeDirectory();
        NSString *scriptPath = [homePath stringByAppendingPathComponent:@".login_failure"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:scriptPath]) {
            NSLog(@"SCRIPT | Failure script not found | Path: %@", scriptPath);
            return; // Silently skip if script doesn't exist
        }
        
        // Check if file is executable
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:scriptPath error:nil];
        NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
        if (!([permissions unsignedShortValue] & 0100)) {
            NSLog(@"WARN   | Script not executable     | Path: %@", scriptPath);
            return;
        }
        
        // Execute with bash (no output logging)
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/bin/bash"];
        [task setArguments:@[scriptPath, method]];
        
        // Set environment variables
        NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
        [env setObject:getUTCTimestamp() forKey:@"AUTH_TIMESTAMP"];
        [env setObject:NSUserName() forKey:@"AUTH_USER"];
        [env setObject:@"FAILED" forKey:@"AUTH_RESULT"];
        [env setObject:method forKey:@"AUTH_METHOD"];
        [task setEnvironment:env];
        
        // Suppress output
        [task setStandardOutput:[NSPipe pipe]];
        [task setStandardError:[NSPipe pipe]];
        
        @try {
            // Double-check again right before launching to catch very quick unlocks
            if (!isScreenLocked || !checkIfScreenIsLocked()) {
                NSLog(@"SCRIPT | Failure script skipped  | Mac just unlocked");
                return;
            }
            
            [task launch];
            NSLog(@"SCRIPT | Failure script executed | ");
            // Don't wait for script to finish to avoid blocking
        } @catch (NSException *exception) {
            NSLog(@"ERROR  | Failure script failed   | Error: %@", [exception reason]);
        }
    });
}

// MARK: - Log Message Handler
void handleLogLine(NSString *line) {
    if ([line containsString:@"Screen saver unlocked by"]) {
        // Reset all counters on successful auth
        failedAuthCount = 0;
        touchIDFailureCount = 0;
        passwordFailureCount = 0;
        NSLog(@"AUTH   | SUCCESS                 | Method: TouchID");
        executeLoginSuccessScript(@"TouchID");
    } else if ([line containsString:@"setting session authenticated flag"]) {
        // Reset all counters on successful auth
        failedAuthCount = 0;
        touchIDFailureCount = 0;
        passwordFailureCount = 0;
        NSLog(@"AUTH   | SUCCESS                 | Method: Password");
        executeLoginSuccessScript(@"Password");
    } else if ([line containsString:@"APEventTouchIDNoMatch"]) {
        // Increment both total and TouchID-specific counters
        failedAuthCount++;
        touchIDFailureCount++;
        NSLog(@"AUTH   | FAILED [%lu] (Total: %lu)   | Method: TouchID", 
              (unsigned long)touchIDFailureCount, 
              (unsigned long)failedAuthCount);
        executeLoginFailureScript(@"TouchID");
    } else if ([line containsString:@"Failed to authenticate user"]) {
        // Increment both total and Password-specific counters
        failedAuthCount++;
        passwordFailureCount++;
        NSLog(@"AUTH   | FAILED [%lu] (Total: %lu)   | Method: Password", 
              (unsigned long)passwordFailureCount, 
              (unsigned long)failedAuthCount);
        executeLoginFailureScript(@"Password");
    }
}

// MARK: - Update Monitoring State
void updateMonitoringState() {
    if (isScreenLocked && isSystemAwake) {
        startAuthMonitoring();
    } else {
        stopAuthMonitoring();
    }
}

// MARK: - Start Authentication Monitoring
void startAuthMonitoring() {
    if (authMonitorProcess != nil && [authMonitorProcess isRunning]) {
        return;
    }
    
    NSLog(@"AUTH   | Monitoring STARTED      |");
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/log"];
    
    [task setArguments:@[
        @"stream",
        @"--style", @"syslog",
        @"--predicate",
        @"eventMessage CONTAINS \"Screen saver unlocked by\" OR eventMessage CONTAINS \"setting session authenticated flag\" OR eventMessage CONTAINS \"Failed to authenticate user\" OR eventMessage CONTAINS \"APEventTouchIDNoMatch\""
    ]];
    
    logPipe = [[NSPipe alloc] init];
    [task setStandardOutput:logPipe];
    [task setStandardError:logPipe];
    
    outputHandle = [logPipe fileHandleForReading];
    
    [outputHandle setReadabilityHandler:^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (line.length > 0 && ![line containsString:@"Filtering the log data"]) {
            handleLogLine(line);
        }
    }];
    
    @try {
        [task launch];
        authMonitorProcess = task;
    } @catch (NSException *exception) {
        NSLog(@"ERROR  | Monitor start failed      | %@", [exception reason]);
    }
}

// MARK: - Stop Authentication Monitoring
void stopAuthMonitoring() {
    if (authMonitorProcess == nil || ![authMonitorProcess isRunning]) {
        return;
    }
    
    NSLog(@"AUTH   | Monitoring STOPPED      |");
    
    if (outputHandle != nil) {
        [outputHandle setReadabilityHandler:nil];
        [outputHandle closeFile];
        outputHandle = nil;
    }
    
    [authMonitorProcess terminate];
    authMonitorProcess = nil;
    logPipe = nil;
}

// MARK: - Version and Usage
void printVersion() {
    printf("loginwatcher version %s\n", LOGINWATCHER_VERSION);
}

void printUsage() {
    printf("Usage: loginwatcher [options]\n\n");
    printf("Options:\n");
    printf("  --version     Print version information and exit\n");
    printf("  --help        Print this help message and exit\n\n");
    printf("Description:\n");
    printf("  loginwatcher monitors macOS login attempts and executes scripts\n");
    printf("  on successful or failed authentication attempts.\n\n");
    printf("Scripts:\n");
    printf("  ~/.login_success - Executed on successful authentication\n");
    printf("  ~/.login_failure - Executed on failed authentication\n\n");
    printf("Environment variables passed to scripts:\n");
    printf("  AUTH_TIMESTAMP - UTC timestamp of auth event\n");
    printf("  AUTH_USER     - Username\n");
    printf("  AUTH_RESULT   - \"SUCCESS\" or \"FAILED\"\n");
    printf("  AUTH_METHOD   - \"TouchID\" or \"Password\"\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Check for command line arguments
        if (argc > 1) {
            NSString *arg = [NSString stringWithUTF8String:argv[1]];
            
            if ([arg isEqualToString:@"--version"]) {
                printVersion();
                return 0;
            } else if ([arg isEqualToString:@"--help"]) {
                printUsage();
                return 0;
            } else {
                fprintf(stderr, "Unknown option: %s\n", argv[1]);
                printUsage();
                return 1;
            }
        }
        
        NSLog(@"SYSTEM | Loginwatcher v%s starting up", LOGINWATCHER_VERSION);
        NSLog(@"SYSTEM | Listening for system events");
        
        // MARK: - Set up screen lock/unlock notifications
        NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
        
        [center addObserverForName:@"com.apple.screenIsLocked" 
                            object:nil 
                             queue:nil 
                        usingBlock:^(NSNotification * _Nonnull notification) {
            NSLog(@"EVENT  | Screen LOCKED           | State : locked=YES, awake=%@", 
                  isSystemAwake ? @"YES" : @"NO");
            isScreenLocked = YES;
            updateMonitoringState();
        }];
        
        [center addObserverForName:@"com.apple.screenIsUnlocked" 
                            object:nil 
                             queue:nil 
                        usingBlock:^(NSNotification * _Nonnull notification) {
            NSLog(@"EVENT  | Screen UNLOCKED         | State : locked=NO , awake=%@", 
                  isSystemAwake ? @"YES" : @"NO");
            isScreenLocked = NO;
            updateMonitoringState();
        }];
        
        // MARK: - Set up sleep/wake notifications using NSWorkspace
        NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
        
        [workspaceCenter addObserverForName:NSWorkspaceWillSleepNotification
                                     object:nil
                                      queue:nil
                                 usingBlock:^(NSNotification * _Nonnull note) {
            NSLog(@"EVENT  | System SLEEP            | State : locked=%@, awake=NO", 
                  isScreenLocked ? @"YES" : @"NO");
            isSystemAwake = NO;
            updateMonitoringState();
        }];
        
        [workspaceCenter addObserverForName:NSWorkspaceDidWakeNotification
                                     object:nil
                                      queue:nil
                                 usingBlock:^(NSNotification * _Nonnull note) {
            NSLog(@"EVENT  | System WAKE             | State : locked=%@, awake=YES", 
                  isScreenLocked ? @"YES" : @"NO");
            isSystemAwake = YES;
            updateMonitoringState();
        }];
        
        // Check initial screen lock state
        isScreenLocked = checkIfScreenIsLocked();
        updateMonitoringState();
        
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

