#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// Version information
#define LOGINWATCHER_VERSION "1.0.2"

// MARK: - Global State
BOOL isScreenLocked = NO;
BOOL isSystemAwake = YES;
NSTask *authMonitorProcess = nil;
NSFileHandle *outputHandle = nil;
NSPipe *logPipe = nil;
NSUInteger failedAuthCount = 0;      // Total failures across all methods
NSUInteger touchIDFailureCount = 0;  // TouchID-specific failures
NSUInteger passwordFailureCount = 0; // Password-specific failures
BOOL hasConfigurationScripts = NO;   // Flag to track if any script configurations exist

// Function prototypes
void executeLoginSuccessScript(NSString *method);
void executeLoginFailureScript(NSString *method);
BOOL executeCustomFailureScripts(NSString *method);
BOOL checkForConfigurationScripts(void);
NSArray* parseFailureScripts(NSString *configLine);
void updateMonitoringState(void);
void startAuthMonitoring(void);
void stopAuthMonitoring(void);
BOOL checkIfScreenIsLocked(void);
void printVersion(void);
void printUsage(void);
BOOL setupScriptFiles(void);

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

// MARK: - Parse failure script configuration
NSArray* parseFailureScripts(NSString *configLine) {
    NSMutableArray *scripts = [NSMutableArray array];
    
    // Skip if line is empty or doesn't have a threshold specifier
    if (configLine.length == 0 || ![configLine containsString:@"{"]) {
        return scripts;
    }
    
    NSString *trimmed = [configLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSRange scriptRange = [trimmed rangeOfString:@"{"];
    
    if (scriptRange.location == NSNotFound) {
        return scripts;
    }
    
    // Extract the script path and the threshold specifier
    NSString *scriptPath = [trimmed substringToIndex:scriptRange.location];
    scriptPath = [scriptPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    NSString *thresholdPart = [trimmed substringFromIndex:scriptRange.location];
    thresholdPart = [thresholdPart stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"{} "]];
    
    // Parse threshold specifiers (method:count or special keywords)
    NSArray *specifiers = [thresholdPart componentsSeparatedByString:@","];
    for (NSString *spec in specifiers) {
        NSArray *parts = [spec componentsSeparatedByString:@":"];
        
        // Handle special case: everytime keyword
        if (parts.count == 1 && [[parts[0] lowercaseString] isEqualToString:@"everytime"]) {
            [scripts addObject:@{
                @"path": scriptPath,
                @"method": @"everytime",
                @"threshold": @(0)  // 0 means run every time
            }];
            continue;
        }
        
        // Handle normal method:count format
        if (parts.count == 2) {
            NSString *method = [parts[0] lowercaseString];
            NSInteger threshold = [parts[1] integerValue];
            
            if (threshold > 0) {
                [scripts addObject:@{
                    @"path": scriptPath,
                    @"method": method,
                    @"threshold": @(threshold)
                }];
            }
        }
    }
    
    return scripts;
}

// MARK: - Check if config file has any script configurations
BOOL checkForConfigurationScripts() {
    NSString *homePath = NSHomeDirectory();
    NSString *configPath = [homePath stringByAppendingPathComponent:@".login_failure"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:configPath]) {
        return NO;
    }
    
    // Read the config file
    NSError *error = nil;
    NSString *fileContent = [NSString stringWithContentsOfFile:configPath 
                                                      encoding:NSUTF8StringEncoding 
                                                         error:&error];
    
    if (error) {
        return NO;
    }
    
    // Check for configuration entries
    NSArray *lines = [fileContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    
    // First check for threshold-based configurations
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }
        
        // Check for threshold specifiers
        if ([trimmed containsString:@"{"]) {
            return YES;
        }
    }
    
    // Then check for simple script paths
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"] || [trimmed containsString:@"{"]) {
            continue;
        }
        
        // Found a script path without threshold
        return YES;
    }
    
    return NO;
}

// MARK: - Execute Custom Failure Scripts
BOOL executeCustomFailureScripts(NSString *method) {
    NSString *homePath = NSHomeDirectory();
    NSString *configPath = [homePath stringByAppendingPathComponent:@".login_failure"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:configPath]) {
        NSLog(@"SCRIPT | Failure config not found | Path: %@", configPath);
        return NO;
    }
    
    // Read the config file
    NSError *error = nil;
    NSString *fileContent = [NSString stringWithContentsOfFile:configPath 
                                                      encoding:NSUTF8StringEncoding 
                                                         error:&error];
    
    if (error) {
        NSLog(@"ERROR  | Failed to read config   | Error: %@", error.localizedDescription);
        return NO;
    }
    
    // Parse each line to find script configurations
    NSArray *lines = [fileContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL scriptExecuted = NO;
    BOOL hasThresholdScripts = NO;
    
    // First scan for threshold-based scripts
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmedLine.length == 0 || [trimmedLine hasPrefix:@"#"]) {
            continue;
        }
        
        // Check if this line contains a threshold configuration
        if ([trimmedLine containsString:@"{"]) {
            hasThresholdScripts = YES;
            NSArray *scriptConfigs = parseFailureScripts(line);
            
            for (NSDictionary *config in scriptConfigs) {
                NSString *scriptPath = config[@"path"];
                NSString *configMethod = config[@"method"];
                NSInteger threshold = [config[@"threshold"] integerValue];
                
                // Determine if this script should run based on method and threshold
                BOOL shouldRun = NO;
                
                // Convert method to lowercase for case-insensitive comparison
                NSString *lowerMethod = [method lowercaseString];
                
                if ([configMethod isEqualToString:@"everytime"]) {
                    // Run the script on every failure
                    shouldRun = YES;
                } else if ([configMethod isEqualToString:@"total"] && failedAuthCount == threshold) {
                    shouldRun = YES;
                } else if ([configMethod isEqualToString:@"touchid"] && 
                           [lowerMethod isEqualToString:@"touchid"] && 
                           touchIDFailureCount == threshold) {
                    shouldRun = YES;
                } else if ([configMethod isEqualToString:@"password"] && 
                           [lowerMethod isEqualToString:@"password"] && 
                           passwordFailureCount == threshold) {
                    shouldRun = YES;
                }
                
                if (shouldRun) {
                    // Execute the script
                    NSTask *task = [[NSTask alloc] init];
                    [task setLaunchPath:@"/bin/bash"];
                    [task setArguments:@[@"-c", scriptPath]];
                    
                    // Set environment variables
                    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
                    [env setObject:getUTCTimestamp() forKey:@"AUTH_TIMESTAMP"];
                    [env setObject:NSUserName() forKey:@"AUTH_USER"];
                    [env setObject:@"FAILED" forKey:@"AUTH_RESULT"];
                    [env setObject:method forKey:@"AUTH_METHOD"];
                    [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)failedAuthCount] forKey:@"TOTAL_FAILURES"];
                    [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)touchIDFailureCount] forKey:@"TOUCHID_FAILURES"];
                    [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)passwordFailureCount] forKey:@"PASSWORD_FAILURES"];
                    [task setEnvironment:env];
                    
                    // Suppress output
                    [task setStandardOutput:[NSPipe pipe]];
                    [task setStandardError:[NSPipe pipe]];
                    
                    @try {
                        [task launch];
                        NSLog(@"SCRIPT | Custom script executed  | Path: %@ | Threshold: %ld | Method: %@", 
                              scriptPath, (long)threshold, configMethod);
                        scriptExecuted = YES;
                    } @catch (NSException *exception) {
                        NSLog(@"ERROR  | Custom script failed   | Path: %@ | Error: %@", 
                              scriptPath, [exception reason]);
                    }
                }
            }
        }
    }
    
    // Now look for scripts without thresholds (first failure only)
    if (!scriptExecuted && failedAuthCount == 1) {
        for (NSString *line in lines) {
            // Skip empty lines, comments, and lines with threshold specifiers
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length == 0 || [trimmed hasPrefix:@"#"] || [trimmed containsString:@"{"]) {
                continue;
            }
            
            // Found a script path without threshold - run on first failure
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/bin/bash"];
            [task setArguments:@[@"-c", trimmed]];
            
            // Set environment variables
            NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
            [env setObject:getUTCTimestamp() forKey:@"AUTH_TIMESTAMP"];
            [env setObject:NSUserName() forKey:@"AUTH_USER"];
            [env setObject:@"FAILED" forKey:@"AUTH_RESULT"];
            [env setObject:method forKey:@"AUTH_METHOD"];
            [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)failedAuthCount] forKey:@"TOTAL_FAILURES"];
            [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)touchIDFailureCount] forKey:@"TOUCHID_FAILURES"];
            [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)passwordFailureCount] forKey:@"PASSWORD_FAILURES"];
            [task setEnvironment:env];
            
            // Suppress output
            [task setStandardOutput:[NSPipe pipe]];
            [task setStandardError:[NSPipe pipe]];
            
            @try {
                [task launch];
                NSLog(@"SCRIPT | Default script executed | Path: %@ | First failure", trimmed);
                scriptExecuted = YES;
            } @catch (NSException *exception) {
                NSLog(@"ERROR  | Default script failed   | Path: %@ | Error: %@", 
                      trimmed, [exception reason]);
            }
        }
    }
    
    // Log if no script was executed and explain why
    if (!scriptExecuted) {
        if (hasThresholdScripts) {
            // We have threshold scripts but none matched this failure count
            NSLog(@"SCRIPT | No script executed      | Reason: No matching threshold for %@ failure #%lu", 
                  method, [method isEqualToString:@"TouchID"] ? (unsigned long)touchIDFailureCount : (unsigned long)passwordFailureCount);
        } else if (failedAuthCount > 1) {
            // We have non-threshold scripts but they only run on first failure
            NSLog(@"SCRIPT | No script executed      | Reason: Non-threshold scripts only run on first failure");
        } else {
            NSLog(@"SCRIPT | No script executed      | Reason: No script configurations found");
        }
    }
    
    return scriptExecuted;
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
        
        // Check once at startup if there are any configuration scripts
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            hasConfigurationScripts = checkForConfigurationScripts();
            NSLog(@"SCRIPT | Configuration detection | Has configs: %@", 
                  hasConfigurationScripts ? @"YES" : @"NO");
        });
        
        // First try to parse the file for configurations
        BOOL scriptExecuted = executeCustomFailureScripts(method);
        
        // Only if no script was executed from configuration AND there are no 
        // configuration scripts defined at all, treat it as a direct script
        if (!scriptExecuted && !hasConfigurationScripts) {
            // Check if file is executable
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:scriptPath error:nil];
            NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
            if (([permissions unsignedShortValue] & 0100)) {
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
                [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)failedAuthCount] forKey:@"TOTAL_FAILURES"];
                [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)touchIDFailureCount] forKey:@"TOUCHID_FAILURES"];
                [env setObject:[NSString stringWithFormat:@"%lu", (unsigned long)passwordFailureCount] forKey:@"PASSWORD_FAILURES"];
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
                    NSLog(@"SCRIPT | Failure script executed | Direct execution");
                    // Don't wait for script to finish to avoid blocking
                } @catch (NSException *exception) {
                    NSLog(@"ERROR  | Failure script failed   | Error: %@", [exception reason]);
                }
            } else {
                NSLog(@"WARN   | No scripts executed     | No valid configuration found");
            }
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

// MARK: - Setup Script Files
BOOL setupScriptFiles() {
    NSString *homePath = NSHomeDirectory();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL success = YES;
    
    // Success script template
    NSString *successScriptPath = [homePath stringByAppendingPathComponent:@".login_success"];
    if (![fileManager fileExistsAtPath:successScriptPath]) {
        NSString *successScriptContent = 
        @"# LOGINWATCHER SUCCESS SCRIPT\n";
        
        success = [successScriptContent writeToFile:successScriptPath 
                                         atomically:YES 
                                           encoding:NSUTF8StringEncoding 
                                              error:&error];
        
        if (!success) {
            printf("Error creating .login_success: %s\n", [error.localizedDescription UTF8String]);
            return NO;
        }
        
        // Make executable
        if (![fileManager setAttributes:@{NSFilePosixPermissions:@(0755)} 
                          ofItemAtPath:successScriptPath 
                                 error:&error]) {
            printf("Error setting permissions for .login_success: %s\n", [error.localizedDescription UTF8String]);
            return NO;
        }
        
        printf("Created and made executable: ~/.login_success\n");
    } else {
        printf("File already exists: ~/.login_success\n");
    }
    
    // Failure script template
    NSString *failureScriptPath = [homePath stringByAppendingPathComponent:@".login_failure"];
    if (![fileManager fileExistsAtPath:failureScriptPath]) {
        NSString *failureScriptContent = 
        @"# LOGINWATCHER FAILURE SCRIPT\n";
        
        success = [failureScriptContent writeToFile:failureScriptPath 
                                        atomically:YES 
                                          encoding:NSUTF8StringEncoding 
                                             error:&error];
        
        if (!success) {
            printf("Error creating .login_failure: %s\n", [error.localizedDescription UTF8String]);
            return NO;
        }
        
        // Make executable - added this part to make the failure script executable
        if (![fileManager setAttributes:@{NSFilePosixPermissions:@(0755)} 
                          ofItemAtPath:failureScriptPath 
                                 error:&error]) {
            printf("Error setting permissions for .login_failure: %s\n", [error.localizedDescription UTF8String]);
            return NO;
        }
        
        printf("Created and made executable: ~/.login_failure\n");
    } else {
        printf("File already exists: ~/.login_failure\n");
    }
    
    printf("\nSetup complete!\n\n");
    printf("To use loginwatcher run:\n");
    printf("brew services start loginwatcher\n\n");
    printf("Edit ~/.login_success and ~/.login_failure to customize your scripts.\n\n");
    
    return YES;
}

// MARK: - Version and Usage
void printVersion() {
    printf("loginwatcher version %s\n", LOGINWATCHER_VERSION);
}

void printUsage() {
    printf("\nloginwatcher - version 1.0.3\n\n");
    printf("Description:\n");
    printf("  loginwatcher monitors macOS login attempts and executes scripts\n");
    printf("  on successful or failed authentication attempts.\n\n");
    printf("Usage: loginwatcher [options]\n\n");
    printf("Options:\n");
    printf("  --version     Print version information\n");
    printf("  --help        Print this help message\n");
    printf("  --setup       Create example configuration files and scripts\n");
    printf("  --monitor     Start monitoring for authentication events (optional) \n\n");
    printf("Scripts:\n");
    printf("  ~/.login_success - Executed on successful authentication\n");
    printf("  ~/.login_failure - Executed on failed authentication\n\n");
    printf("Advanced: Configuring failure scripts based on failure counts:\n");
    printf("  In ~/.login_failure, you can specify scripts with different behaviors:\n");
    printf("  - Default (runs on first failure only): ~/script.sh\n");
    printf("  - Run after specific counts: ~/script.sh {method:count,...}\n");
    printf("  - Run on every failure: ~/script.sh {everytime}\n");
    printf("  Examples:\n");
    printf("    ~/notify.sh                    # first failure only\n");
    printf("    ~/log.sh {everytime}           # every failure\n");
    printf("    ~/alert.sh {total:3,touchid:5} # specific counts\n");
    printf("  Available methods: everytime, total, touchid, password\n\n");
    printf("Getting Started:\n");
    printf("  1. Run 'loginwatcher --setup' to create example configuration files\n");
    printf("  2. Edit ~/.login_failure to customize your failure scripts\n");
    printf("  3. Start the service with 'brew services start loginwatcher'\n\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Check for command line arguments
        if (argc == 1) {
            // No arguments provided - show help by default
            printUsage();
            return 0;
        }
        
        NSString *arg = nil;
        if (argc > 1) {
            arg = [NSString stringWithUTF8String:argv[1]];
        }
            
        if (arg && [arg isEqualToString:@"--version"]) {
            printVersion();
            return 0;
        } else if (arg && [arg isEqualToString:@"--help"]) {
            printUsage();
            return 0;
        } else if (arg && [arg isEqualToString:@"--setup"]) {
            return setupScriptFiles() ? 0 : 1;
        } else if (arg && [arg isEqualToString:@"--monitor"]) {
            // Run in monitor mode (default when starting daemon)
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[1]);
            printUsage();
            return 1;
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