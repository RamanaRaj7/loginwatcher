#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <signal.h>

// Version information
#define LOGINWATCHER_VERSION "1.0.4"

// Color definitions - matching the monitor configuration utility theme exactly
#define ANSI_RESET      "\033[0m"
#define ANSI_BOLD       "\033[1m"
#define ANSI_ACCENT     "\033[0;36m"     // Cyan for headings and highlights
#define ANSI_PRIMARY    "\033[0;36m"     // Cyan for primary elements
#define ANSI_SUCCESS    "\033[0;32m"     // Green for success/enabled states
#define ANSI_WARNING    "\033[0;33m"     // Yellow for warnings/optional states
#define ANSI_ERROR      "\033[0;31m"     // Red for errors/disabled states

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
BOOL isMonitoringMode = NO;          // Flag to track if we're in monitoring mode

// Script execution configuration
BOOL loginSuccessEnabled = YES;
BOOL loginFailureEnabled = YES;
BOOL sleepEnabled = NO;
BOOL wakeupEnabled = NO;
NSString *configPath = nil;          // Path to the configuration file

// Function prototypes
void executeLoginSuccessScript(NSString *method);
void executeLoginFailureScript(NSString *method);
void executeSleepScript(void);
void executeWakeupScript(void);
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
BOOL configureScriptExecution(void);
void loadConfiguration(void);
void saveConfiguration(void);
void colorLog(const char *color, NSString *prefix, NSString *message, NSString *details);
void printHeader(NSString *title);
void cleanup(void);
void handleSignal(int signal);

// MARK: - Timestamp Formatter
NSString* getUTCTimestamp() {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    return [formatter stringFromDate:[NSDate date]];
}

// MARK: - Helper function for colorized logging
void colorLog(const char *color, NSString *prefix, NSString *message, NSString *details) {
    if (details) {
        NSLog(@"%s%-7s| %-24s | %s%s", color, [prefix UTF8String], [message UTF8String], [details UTF8String], ANSI_RESET);
    } else {
        NSLog(@"%s%-7s| %-24s |%s", color, [prefix UTF8String], [message UTF8String], ANSI_RESET);
    }
}

// MARK: - Pretty header for console output
void printHeader(NSString *title) {
    printf("\n%s%s╔════════════════════════════════════════════════════╗%s\n", ANSI_ACCENT, ANSI_BOLD, ANSI_RESET);
    printf("%s%s║ %-50s ║%s\n", ANSI_ACCENT, ANSI_BOLD, [title UTF8String], ANSI_RESET);
    printf("%s%s╚════════════════════════════════════════════════════╝%s\n\n", ANSI_ACCENT, ANSI_BOLD, ANSI_RESET);
}

// MARK: - Load Configuration
void loadConfiguration() {
    NSString *homePath = NSHomeDirectory();
    NSString *configDir = [homePath stringByAppendingPathComponent:@".config"];
    configPath = [configDir stringByAppendingPathComponent:@"loginwatcher.conf"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Create the .config directory if it doesn't exist
    if (![fileManager fileExistsAtPath:configDir]) {
        NSError *dirError = nil;
        [fileManager createDirectoryAtPath:configDir 
                withIntermediateDirectories:YES 
                                 attributes:nil 
                                      error:&dirError];
        if (dirError) {
            colorLog(ANSI_ERROR, @"CONFIG", @"Failed to create config dir", [dirError localizedDescription]);
            // Fall back to home directory
            configPath = [homePath stringByAppendingPathComponent:@".loginwatcher_config"];
        }
    }
    
    if (![fileManager fileExistsAtPath:configPath]) {
        // Create default configuration
        saveConfiguration();
        return;
    }
    
    NSError *error = nil;
    NSString *fileContent = [NSString stringWithContentsOfFile:configPath 
                                                      encoding:NSUTF8StringEncoding 
                                                         error:&error];
    
    if (error) {
        colorLog(ANSI_WARNING, @"CONFIG", @"Failed to load config", [error localizedDescription]);
        return;
    }
    
    // Parse configuration file
    NSArray *lines = [fileContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) {
            continue;
        }
        
        NSArray *parts = [trimmed componentsSeparatedByString:@"="];
        if (parts.count != 2) continue;
        
        NSString *key = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        if ([key isEqualToString:@"LOGIN_SUCCESS_ENABLED"]) {
            loginSuccessEnabled = [value isEqualToString:@"YES"];
        } else if ([key isEqualToString:@"LOGIN_FAILURE_ENABLED"]) {
            loginFailureEnabled = [value isEqualToString:@"YES"];
        } else if ([key isEqualToString:@"SLEEP_ENABLED"]) {
            sleepEnabled = [value isEqualToString:@"YES"];
        } else if ([key isEqualToString:@"WAKEUP_ENABLED"]) {
            wakeupEnabled = [value isEqualToString:@"YES"];
        }
    }
    
    colorLog(ANSI_SUCCESS, @"CONFIG", @"Configuration loaded", [NSString stringWithFormat:@"Path: %@", configPath]);
}
// MARK: - Save Configuration
void saveConfiguration() {
    NSString *configContent = [NSString stringWithFormat:
                              @"# LoginWatcher Configuration\n"
                              @"# Last updated: %@\n"
                              @"\n"
                              @"# Enable/disable script execution for different events\n"
                              @"LOGIN_SUCCESS_ENABLED=%@\n"
                              @"LOGIN_FAILURE_ENABLED=%@\n"
                              @"SLEEP_ENABLED=%@\n"
                              @"WAKEUP_ENABLED=%@\n",
                              getUTCTimestamp(),
                              loginSuccessEnabled ? @"YES" : @"NO",
                              loginFailureEnabled ? @"YES" : @"NO",
                              sleepEnabled ? @"YES" : @"NO",
                              wakeupEnabled ? @"YES" : @"NO"];
    
    NSError *error = nil;
    BOOL success = [configContent writeToFile:configPath
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:&error];
    
    if (!success) {
        colorLog(ANSI_ERROR, @"CONFIG", @"Failed to save config", [error localizedDescription]);
    } else {
        colorLog(ANSI_SUCCESS, @"CONFIG", @"Configuration saved", [NSString stringWithFormat:@"Path: %@", configPath]);
    }
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

// MARK: - Execute Sleep Script
void executeSleepScript() {
    if (!sleepEnabled) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Sleep script disabled", @"Skipping execution");
        return;
    }
    
    NSString *homePath = NSHomeDirectory();
    NSString *scriptPath = [homePath stringByAppendingPathComponent:@".sleep"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:scriptPath]) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Sleep script not found", [NSString stringWithFormat:@"Path: %@", scriptPath]);
        return;
    }
    
    // Check if file is executable
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:scriptPath error:nil];
    NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
    if (!([permissions unsignedShortValue] & 0100)) {
        colorLog(ANSI_WARNING, @"WARN", @"Script not executable", [NSString stringWithFormat:@"Path: %@", scriptPath]);
        return;
    }
    
    // Execute with bash
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/bash"];
    [task setArguments:@[scriptPath]];
    
    // Set environment variables
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"SLEEP" forKey:@"EVENT_TYPE"];
    [env setObject:[NSString stringWithFormat:@"%@", isScreenLocked ? @"YES" : @"NO"] forKey:@"SCREEN_LOCKED"];
    [task setEnvironment:env];
    
    // Suppress output
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        colorLog(ANSI_SUCCESS, @"SCRIPT", @"Sleep script executed", nil);
    } @catch (NSException *exception) {
        colorLog(ANSI_ERROR, @"ERROR", @"Sleep script failed", [NSString stringWithFormat:@"Error: %@", [exception reason]]);
    }
}

// MARK: - Execute Wakeup Script
void executeWakeupScript() {
    if (!wakeupEnabled) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Wakeup script disabled", @"Skipping execution");
        return;
    }
    
    NSString *homePath = NSHomeDirectory();
    NSString *scriptPath = [homePath stringByAppendingPathComponent:@".wakeup"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:scriptPath]) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Wakeup script not found", [NSString stringWithFormat:@"Path: %@", scriptPath]);
        return;
    }
    
    // Check if file is executable
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:scriptPath error:nil];
    NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
    if (!([permissions unsignedShortValue] & 0100)) {
        colorLog(ANSI_WARNING, @"WARN", @"Script not executable", [NSString stringWithFormat:@"Path: %@", scriptPath]);
        return;
    }
    
    // Execute with bash
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/bash"];
    [task setArguments:@[scriptPath]];
    
    // Set environment variables
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"WAKEUP" forKey:@"EVENT_TYPE"];
    [env setObject:[NSString stringWithFormat:@"%@", isScreenLocked ? @"YES" : @"NO"] forKey:@"SCREEN_LOCKED"];
    [task setEnvironment:env];
    
    // Suppress output
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        colorLog(ANSI_SUCCESS, @"SCRIPT", @"Wakeup script executed", nil);
    } @catch (NSException *exception) {
        colorLog(ANSI_ERROR, @"ERROR", @"Wakeup script failed", [NSString stringWithFormat:@"Error: %@", [exception reason]]);
    }
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
        colorLog(ANSI_WARNING, @"SCRIPT", @"Failure config not found", [NSString stringWithFormat:@"Path: %@", configPath]);
        return NO;
    }
    
    // Read the config file
    NSError *error = nil;
    NSString *fileContent = [NSString stringWithContentsOfFile:configPath 
                                                      encoding:NSUTF8StringEncoding 
                                                         error:&error];
    
    if (error) {
        colorLog(ANSI_ERROR, @"ERROR", @"Failed to read config", [NSString stringWithFormat:@"Error: %@", error.localizedDescription]);
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
                        colorLog(ANSI_SUCCESS, @"SCRIPT", @"Custom script executed", 
                               [NSString stringWithFormat:@"Path: %@ | Threshold: %ld | Method: %@", 
                               scriptPath, (long)threshold, configMethod]);
                        scriptExecuted = YES;
                    } @catch (NSException *exception) {
                        colorLog(ANSI_ERROR, @"ERROR", @"Custom script failed", 
                               [NSString stringWithFormat:@"Path: %@ | Error: %@", 
                               scriptPath, [exception reason]]);
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
                colorLog(ANSI_SUCCESS, @"SCRIPT", @"Default script executed", [NSString stringWithFormat:@"Path: %@ | First failure", trimmed]);
                scriptExecuted = YES;
            } @catch (NSException *exception) {
                colorLog(ANSI_ERROR, @"ERROR", @"Default script failed", 
                      [NSString stringWithFormat:@"Path: %@ | Error: %@", 
                      trimmed, [exception reason]]);
            }
        }
    }
    
    // Log if no script was executed and explain why
    if (!scriptExecuted) {
        if (hasThresholdScripts) {
            // We have threshold scripts but none matched this failure count
            colorLog(ANSI_WARNING, @"SCRIPT", @"No script executed", 
                  [NSString stringWithFormat:@"Reason: No matching threshold for %@ failure #%lu", 
                  method, [method isEqualToString:@"TouchID"] ? (unsigned long)touchIDFailureCount : (unsigned long)passwordFailureCount]);
        } else if (failedAuthCount > 1) {
            // We have non-threshold scripts but they only run on first failure
            colorLog(ANSI_WARNING, @"SCRIPT", @"No script executed", @"Reason: Non-threshold scripts only run on first failure");
        } else {
            colorLog(ANSI_WARNING, @"SCRIPT", @"No script executed", @"Reason: No script configurations found");
        }
    }
    
    return scriptExecuted;
}

// MARK: - Script Execution (without logging script results)
void executeLoginSuccessScript(NSString *method) {
    if (!loginSuccessEnabled) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Success script disabled", @"Skipping execution");
        return;
    }
    
    NSString *homePath = NSHomeDirectory();
    NSString *scriptPath = [homePath stringByAppendingPathComponent:@".login_success"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:scriptPath]) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Success script not found", [NSString stringWithFormat:@"Path: %@", scriptPath]);
        return; // Silently skip if script doesn't exist
    }
    
    // Check if file is executable
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:scriptPath error:nil];
    NSNumber *permissions = [attributes objectForKey:NSFilePosixPermissions];
    if (!([permissions unsignedShortValue] & 0100)) {
        colorLog(ANSI_WARNING, @"WARN", @"Script not executable", [NSString stringWithFormat:@"Path: %@", scriptPath]);
        return;
    }
    
    // Execute with bash (no output logging)
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/bash"];
    [task setArguments:@[scriptPath, method]];
    
    // Set environment variables
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"SUCCESS" forKey:@"AUTH_RESULT"];
    [env setObject:method forKey:@"AUTH_METHOD"];
    [task setEnvironment:env];
    
    // Suppress output
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        colorLog(ANSI_SUCCESS, @"SCRIPT", @"Success script executed", nil);
        // Don't wait for script to finish to avoid blocking
    } @catch (NSException *exception) {
        colorLog(ANSI_ERROR, @"ERROR", @"Success script failed", [NSString stringWithFormat:@"Error: %@", [exception reason]]);
    }
}

void executeLoginFailureScript(NSString *method) {
    if (!loginFailureEnabled) {
        colorLog(ANSI_WARNING, @"SCRIPT", @"Failure script disabled", @"Skipping execution");
        return;
    }
    
    // IMPORTANT: Use dispatch_after to introduce a small delay to check if the
    // screen is still locked before executing the failure script. This helps
    // avoid the race condition where unlock happens during auth failure processing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Check if Mac is already unlocked - if so, don't execute the failure script
        if (!isScreenLocked || !checkIfScreenIsLocked()) {
            colorLog(ANSI_WARNING, @"SCRIPT", @"Failure script skipped", @"Mac is already unlocked");
            return;
        }
        
        NSString *homePath = NSHomeDirectory();
        NSString *scriptPath = [homePath stringByAppendingPathComponent:@".login_failure"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:scriptPath]) {
            colorLog(ANSI_WARNING, @"SCRIPT", @"Failure script not found", [NSString stringWithFormat:@"Path: %@", scriptPath]);
            return; // Silently skip if script doesn't exist
        }
        
        // Check once at startup if there are any configuration scripts
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            hasConfigurationScripts = checkForConfigurationScripts();
            colorLog(ANSI_PRIMARY, @"SCRIPT", @"Configuration detection", 
                  [NSString stringWithFormat:@"Has configs: %@", 
                  hasConfigurationScripts ? @"YES" : @"NO"]);
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
                        colorLog(ANSI_WARNING, @"SCRIPT", @"Failure script skipped", @"Mac just unlocked");
                        return;
                    }
                    
                    [task launch];
                    colorLog(ANSI_SUCCESS, @"SCRIPT", @"Failure script executed", @"Direct execution");
                    // Don't wait for script to finish to avoid blocking
                } @catch (NSException *exception) {
                    colorLog(ANSI_ERROR, @"ERROR", @"Failure script failed", [NSString stringWithFormat:@"Error: %@", [exception reason]]);
                }
            } else {
                colorLog(ANSI_WARNING, @"WARN", @"No scripts executed", @"No valid configuration found");
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
        colorLog(ANSI_SUCCESS, @"AUTH", @"SUCCESS", @"Method: TouchID");
        executeLoginSuccessScript(@"TouchID");
    } else if ([line containsString:@"setting session authenticated flag"]) {
        // Reset all counters on successful auth
        failedAuthCount = 0;
        touchIDFailureCount = 0;
        passwordFailureCount = 0;
        colorLog(ANSI_SUCCESS, @"AUTH", @"SUCCESS", @"Method: Password");
        executeLoginSuccessScript(@"Password");
    } else if ([line containsString:@"APEventTouchIDNoMatch"]) {
        // Increment both total and TouchID-specific counters
        failedAuthCount++;
        touchIDFailureCount++;
        colorLog(ANSI_ERROR, @"AUTH", @"FAILED", 
              [NSString stringWithFormat:@"Method: TouchID | Failure #%lu (Total: %lu)", 
              (unsigned long)touchIDFailureCount, (unsigned long)failedAuthCount]);
        executeLoginFailureScript(@"TouchID");
    } else if ([line containsString:@"Failed to authenticate user"]) {
        // Increment both total and Password-specific counters
        failedAuthCount++;
        passwordFailureCount++;
        colorLog(ANSI_ERROR, @"AUTH", @"FAILED", 
              [NSString stringWithFormat:@"Method: Password | Failure #%lu (Total: %lu)", 
              (unsigned long)passwordFailureCount, (unsigned long)failedAuthCount]);
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
    
    // Clean up any existing pipes first to avoid leaks
    if (logPipe != nil) {
        NSFileHandle *readHandle = [logPipe fileHandleForReading];
        NSFileHandle *writeHandle = [logPipe fileHandleForWriting];
        
        if (readHandle) {
            [readHandle setReadabilityHandler:nil];
            [readHandle closeFile];
        }
        
        if (writeHandle) {
            [writeHandle closeFile];
        }
        
        logPipe = nil;
    }
    
    colorLog(ANSI_SUCCESS, @"AUTH", @"Monitoring STARTED", nil);
    
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
        colorLog(ANSI_ERROR, @"ERROR", @"Monitor start failed", [NSString stringWithFormat:@"%@", [exception reason]]);
        // Clean up in case of failure
        if (outputHandle != nil) {
            [outputHandle setReadabilityHandler:nil];
            [outputHandle closeFile];
            outputHandle = nil;
        }
        logPipe = nil;
    }
}

// MARK: - Stop Authentication Monitoring
void stopAuthMonitoring() {
    if (authMonitorProcess == nil || ![authMonitorProcess isRunning]) {
        return;
    }
    
    colorLog(ANSI_WARNING, @"AUTH", @"Monitoring STOPPED", nil);
    
    if (outputHandle != nil) {
        [outputHandle setReadabilityHandler:nil];
        [outputHandle closeFile];
        outputHandle = nil;
    }
    
    // Close pipe file handles explicitly before releasing
    NSFileHandle *readHandle = [logPipe fileHandleForReading];
    NSFileHandle *writeHandle = [logPipe fileHandleForWriting];
    
    if (readHandle) {
        [readHandle closeFile];
    }
    
    if (writeHandle) {
        [writeHandle closeFile]; 
    }
    
    [authMonitorProcess terminate];
    authMonitorProcess = nil;
    logPipe = nil;
}

// MARK: - Configure Script Execution
BOOL configureScriptExecution() {
    printHeader(@"            LOGINWATCHER CONFIGURATION");
    
    while (1) {
        printf("%s◇ SCRIPT EXECUTION SETTINGS%s\n", ANSI_ACCENT, ANSI_RESET);
        printf("  %s[1]%s Login Success Script : %s%s%s\n", 
               ANSI_PRIMARY, ANSI_RESET,
               loginSuccessEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               loginSuccessEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
               
        printf("  %s[2]%s Login Failure Script : %s%s%s\n", 
               ANSI_PRIMARY, ANSI_RESET,
               loginFailureEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               loginFailureEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
               
        printf("  %s[3]%s Sleep Script         : %s%s%s\n", 
               ANSI_PRIMARY, ANSI_RESET,
               sleepEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               sleepEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
               
        printf("  %s[4]%s Wakeup Script        : %s%s%s\n", 
               ANSI_PRIMARY, ANSI_RESET,
               wakeupEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               wakeupEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
               
        printf("  %s[5]%s Save and Exit\n\n", ANSI_PRIMARY, ANSI_RESET);
        
        printf("Enter your choice (1-5): ");
        char choice[10];
        if (fgets(choice, sizeof(choice), stdin) == NULL) {
            printf("\n%sError reading input. Please try again.%s\n", ANSI_ERROR, ANSI_RESET);
            continue;
        }
        
        int option = atoi(choice);
        
        switch (option) {
            case 1:
                loginSuccessEnabled = !loginSuccessEnabled;
                printf("\n%sLogin Success Script %s%s\n\n", 
                       loginSuccessEnabled ? ANSI_SUCCESS : ANSI_WARNING,
                       loginSuccessEnabled ? "Enabled" : "Disabled",
                       ANSI_RESET);
                break;
                
            case 2:
                loginFailureEnabled = !loginFailureEnabled;
                printf("\n%sLogin Failure Script %s%s\n\n", 
                       loginFailureEnabled ? ANSI_SUCCESS : ANSI_WARNING,
                       loginFailureEnabled ? "Enabled" : "Disabled",
                       ANSI_RESET);
                break;
                
            case 3:
                sleepEnabled = !sleepEnabled;
                printf("\n%sSleep Script %s%s\n\n", 
                       sleepEnabled ? ANSI_SUCCESS : ANSI_WARNING,
                       sleepEnabled ? "Enabled" : "Disabled",
                       ANSI_RESET);
                break;
                
            case 4:
                wakeupEnabled = !wakeupEnabled;
                printf("\n%sWakeup Script %s%s\n\n", 
                       wakeupEnabled ? ANSI_SUCCESS : ANSI_WARNING,
                       wakeupEnabled ? "Enabled" : "Disabled",
                       ANSI_RESET);
                break;
                
            case 5:
                saveConfiguration();
                printf("\n%sConfiguration saved successfully.%s\n", ANSI_SUCCESS, ANSI_RESET);
                return YES;
                
            default:
                printf("\n%sInvalid option. Please enter a number between 1 and 5.%s\n\n", ANSI_ERROR, ANSI_RESET);
                break;
        }
    }
    
    return YES;
}

// MARK: - Setup Script Files
BOOL setupScriptFiles() {
    printHeader(@"            LOGINWATCHER SCRIPT SETUP");
    
    NSString *homePath = NSHomeDirectory();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL success = YES;
    
    // Success script template
    NSString *successScriptPath = [homePath stringByAppendingPathComponent:@".login_success"];
    if (![fileManager fileExistsAtPath:successScriptPath]) {
        NSString *successScriptContent = 
        @"#!/bin/bash\n"
        @"# LOGINWATCHER SUCCESS SCRIPT\n"
        @"# Executed when authentication succeeds\n"
        @"# \n";
        
        success = [successScriptContent writeToFile:successScriptPath 
                                         atomically:YES 
                                           encoding:NSUTF8StringEncoding 
                                              error:&error];
        
        if (!success) {
            printf("%sError creating .login_success: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        // Make executable
        if (![fileManager setAttributes:@{NSFilePosixPermissions:@(0755)} 
                          ofItemAtPath:successScriptPath 
                                 error:&error]) {
            printf("%sError setting permissions for .login_success: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        printf("  %sCreated and made executable: ~/.login_success%s\n", ANSI_SUCCESS, ANSI_RESET);
    } else {
        printf("  %sFile already exists: ~/.login_success%s\n", ANSI_WARNING, ANSI_RESET);
    }
    
    // Failure script template
    NSString *failureScriptPath = [homePath stringByAppendingPathComponent:@".login_failure"];
    if (![fileManager fileExistsAtPath:failureScriptPath]) {
        NSString *failureScriptContent = 
        @"#!/bin/bash\n"
        @"# LOGINWATCHER FAILURE SCRIPT\n"
        @"# Executed when authentication fails\n"
        @"# \n"
        @"# ADVANCED CONFIGURATION:\n"
        @"# To run scripts only after specific failure counts:\n"
        @"# /path/to/script.sh {method:count,...}\n"
        @"# \n"
        @"# Examples:\n"
        @"# /Users/user/notify.sh {everytime}\n"
        @"# /Users/user/camera.sh {touchid:3,password:2}\n"
        @"# /Users/user/alert.sh {total:5}\n";
        
        success = [failureScriptContent writeToFile:failureScriptPath 
                                        atomically:YES 
                                          encoding:NSUTF8StringEncoding 
                                             error:&error];
        
        if (!success) {
            printf("%sError creating .login_failure: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        // Make executable - added this part to make the failure script executable
        if (![fileManager setAttributes:@{NSFilePosixPermissions:@(0755)} 
                          ofItemAtPath:failureScriptPath 
                                 error:&error]) {
            printf("%sError setting permissions for .login_failure: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        printf("  %sCreated and made executable: ~/.login_failure%s\n", ANSI_SUCCESS, ANSI_RESET);
    } else {
        printf("  %sFile already exists: ~/.login_failure%s\n", ANSI_WARNING, ANSI_RESET);
    }
    
    // Sleep script template
    NSString *sleepScriptPath = [homePath stringByAppendingPathComponent:@".sleep"];
    if (![fileManager fileExistsAtPath:sleepScriptPath]) {
        NSString *sleepScriptContent = 
        @"#!/bin/bash\n"
        @"# LOGINWATCHER SLEEP SCRIPT\n"
        @"# Executed when system goes to sleep\n"
        @"# \n"
        @"# Environment variables:\n"
        @"#   EVENT_TIMESTAMP - Time of event (UTC)\n"
        @"#   EVENT_USER - Username\n"
        @"#   EVENT_TYPE - Will be \"SLEEP\"\n"
        @"#   SCREEN_LOCKED - Will be \"YES\" or \"NO\"\n";
        
        success = [sleepScriptContent writeToFile:sleepScriptPath 
                                       atomically:YES 
                                         encoding:NSUTF8StringEncoding 
                                            error:&error];
        
        if (!success) {
            printf("%sError creating .sleep: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        // Make executable
        if (![fileManager setAttributes:@{NSFilePosixPermissions:@(0755)} 
                          ofItemAtPath:sleepScriptPath 
                                 error:&error]) {
            printf("%sError setting permissions for .sleep: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        printf("  %sCreated and made executable: ~/.sleep%s\n", ANSI_SUCCESS, ANSI_RESET);
    } else {
        printf("  %sFile already exists: ~/.sleep%s\n", ANSI_WARNING, ANSI_RESET);
    }
    
    // Wakeup script template
    NSString *wakeupScriptPath = [homePath stringByAppendingPathComponent:@".wakeup"];
    if (![fileManager fileExistsAtPath:wakeupScriptPath]) {
        NSString *wakeupScriptContent = 
        @"#!/bin/bash\n"
        @"# LOGINWATCHER WAKEUP SCRIPT\n"
        @"# Executed when system wakes from sleep\n"
        @"# \n"
        @"# Environment variables:\n"
        @"#   EVENT_TIMESTAMP - Time of event (UTC)\n"
        @"#   EVENT_USER - Username\n"
        @"#   EVENT_TYPE - Will be \"WAKEUP\"\n"
        @"#   SCREEN_LOCKED - Will be \"YES\" or \"NO\"\n";
        
        success = [wakeupScriptContent writeToFile:wakeupScriptPath 
                                        atomically:YES 
                                          encoding:NSUTF8StringEncoding 
                                             error:&error];
        
        if (!success) {
            printf("%sError creating .wakeup: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        // Make executable
        if (![fileManager setAttributes:@{NSFilePosixPermissions:@(0755)} 
                          ofItemAtPath:wakeupScriptPath 
                                 error:&error]) {
            printf("%sError setting permissions for .wakeup: %s%s\n", ANSI_ERROR, [error.localizedDescription UTF8String], ANSI_RESET);
            return NO;
        }
        
        printf("  %sCreated and made executable: ~/.wakeup%s\n", ANSI_SUCCESS, ANSI_RESET);
    } else {
        printf("  %sFile already exists: ~/.wakeup%s\n", ANSI_WARNING, ANSI_RESET);
    }
    
    printf("\n%s%sSetup complete!%s\n\n", ANSI_BOLD, ANSI_SUCCESS, ANSI_RESET);
    printf("To use loginwatcher run:\n");
    printf("  %sbrew services start loginwatcher%s\n\n", ANSI_PRIMARY, ANSI_RESET);
    printf("Edit script files to customize your actions using 'nano ~/.filename':\n");
    printf("  %s~/.login_success%s - When login succeeds\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s~/.login_failure%s - When login fails\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s~/.sleep%s         - When system goes to sleep\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s~/.wakeup%s        - When system wakes from sleep\n\n", ANSI_PRIMARY, ANSI_RESET);
    
    printf("To configure which scripts are enabled:\n");
    printf("  %sloginwatcher --config%s\n\n", ANSI_PRIMARY, ANSI_RESET);
    
    printf("%s──────────────────────────────────────────────────────%s\n", ANSI_PRIMARY, ANSI_RESET);
    
    return YES;
}

// MARK: - Version and Usage
void printVersion() {
    printf("%sloginwatcher%s version %s%s%s\n", 
           ANSI_ACCENT,     // Blue for "loginwatcher"
           ANSI_RESET,      // No color for "version"
           ANSI_SUCCESS,    // Green for the version number
           LOGINWATCHER_VERSION,
           ANSI_RESET);     // Reset color at the end
}

void printUsage() {
    printHeader(@"                LOGINWATCHER v1.0.4");
    
    printf("%s◇ DESCRIPTION%s\n", ANSI_ACCENT, ANSI_RESET);
    printf("  loginwatcher monitors macOS login attempts and executes scripts\n");
    printf("  on successful or failed authentication attempts.\n\n");
    
    printf("%s◇ USAGE%s\n", ANSI_ACCENT, ANSI_RESET);
    printf("  loginwatcher [options]\n\n");
    
    printf("%s◇ OPTIONS%s\n", ANSI_ACCENT, ANSI_RESET);
    printf("  %s[1]%s --version     Print version information\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[2]%s --help        Print this help message\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[3]%s --setup       Create example configuration files and scripts\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[4]%s --config      Configure which scripts are enabled\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[5]%s --monitor     Start monitoring for authentication events\n\n", ANSI_PRIMARY, ANSI_RESET);
    
    printf("%s◇ SCRIPTS (to access this run 'nano ~/.filename')%s\n", ANSI_ACCENT, ANSI_RESET);
    printf("  ~/.login_success - Executed on successful authentication\n");
    printf("  ~/.login_failure - Executed on failed authentication\n");
    printf("  ~/.sleep         - Executed when system goes to sleep\n");
    printf("  ~/.wakeup        - Executed when system wakes from sleep\n\n");
    
    printf("%s◇ ADVANCED CONFIGURATION%s\n", ANSI_ACCENT, ANSI_RESET);
    printf("  In ~/.login_failure, you can specify scripts with different behaviors:\n\n");
    printf("  %s[•]%s Default (runs on first failure only):\n", ANSI_PRIMARY, ANSI_RESET);
    printf("      ~/script.sh\n\n");
    printf("  %s[•]%s Run after specific counts:\n", ANSI_PRIMARY, ANSI_RESET);
    printf("      ~/script.sh {method:count,...}\n\n");
    printf("  %s[•]%s Run on every failure:\n", ANSI_PRIMARY, ANSI_RESET);
    printf("      ~/script.sh {everytime}\n\n");
    
    printf("  %sExamples:%s\n", ANSI_SUCCESS, ANSI_RESET);
    printf("    ~/notify.sh                    # first failure only\n");
    printf("    ~/log.sh {everytime}           # every failure\n");
    printf("    ~/alert.sh {total:3,touchid:5} # specific counts\n\n");
    printf("  Available methods: everytime, total, touchid, password\n\n");
    
    printf("%s◇ GETTING STARTED%s\n", ANSI_ACCENT, ANSI_RESET);
    printf("  %s[1]%s Run 'loginwatcher --setup' to create example configuration files\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[2]%s Edit script files to customize your actions\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[3]%s Configure which scripts to enable with 'loginwatcher --config'\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[4]%s Start the service with 'brew services start loginwatcher'\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[5]%s If you get an error then 'brew services restart loginwatcher'\n", ANSI_PRIMARY, ANSI_RESET);
    printf("  %s[6]%s If you want to stop it then 'brew services stop loginwatcher'\n\n", ANSI_PRIMARY, ANSI_RESET);
    printf("%s◇ MORE INFORMATION%s:\n      Visit: %shttps://github.com/ramanaraj7/loginwatcher%s\n\n", 
           ANSI_ACCENT,    
           ANSI_RESET,    
           ANSI_SUCCESS,   
           ANSI_RESET);    
    printf("%s──────────────────────────────────────────────────────%s\n\n", ANSI_PRIMARY, ANSI_RESET);
}

void cleanup(void) {
    static volatile sig_atomic_t alreadyCleaned = 0;
    
    // Only run cleanup once
    if (alreadyCleaned) {
        return;
    }
    alreadyCleaned = 1;
    
    // Only show shutdown messages in monitoring mode
    if (isMonitoringMode) {
        colorLog(ANSI_ACCENT, @"SYSTEM", @"Loginwatcher shutting down", nil);
        stopAuthMonitoring();
        colorLog(ANSI_ACCENT, @"SYSTEM", @"Loginwatcher shutdown complete", nil);
    } else {
        // Just stop monitoring without messages
        stopAuthMonitoring();
    }
}

void handleSignal(int signal) {
    static volatile sig_atomic_t alreadyHandling = 0;
    
    // Prevent re-entrance
    if (alreadyHandling) {
        return;
    }
    
    alreadyHandling = 1;
    cleanup();
    
    // Re-raise the original signal with default handler
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(signal, &sa, NULL);
    raise(signal);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Register cleanup function to run at exit
        atexit(cleanup);
        
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
            
        // Handle commands that don't need configuration
        if (arg && [arg isEqualToString:@"--version"]) {
            printVersion();
            return 0;
        } else if (arg && [arg isEqualToString:@"--help"]) {
            printUsage();
            return 0;
        } else if (arg && [arg isEqualToString:@"--setup"]) {
            return setupScriptFiles() ? 0 : 1;
        }
        
        // Only load configuration for commands that need it
        loadConfiguration();
            
        if (arg && [arg isEqualToString:@"--config"]) {
            return configureScriptExecution() ? 0 : 1;
        } else if (arg && [arg isEqualToString:@"--monitor"]) {
            // Set monitoring mode flag
            isMonitoringMode = YES;
        } else {
            fprintf(stderr, "%sUnknown option: %s%s\n", ANSI_ERROR, argv[1], ANSI_RESET);
            printUsage();
            return 1;
        }
        
        printHeader(@"               LOGINWATCHER MONITOR");
        
        colorLog(ANSI_ACCENT, @"SYSTEM", [NSString stringWithFormat:@"Loginwatcher v%s starting up", LOGINWATCHER_VERSION], nil);
        colorLog(ANSI_ACCENT, @"SYSTEM", @"Listening for system events    ", nil);
        
        // Print script status
        printf("\n%s◇ SCRIPT STATUS%s\n", ANSI_ACCENT, ANSI_RESET);
        printf("  Login Success: %s%s%s\n", 
               loginSuccessEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               loginSuccessEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
        printf("  Login Failure: %s%s%s\n", 
               loginFailureEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               loginFailureEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
        printf("  Sleep Events : %s%s%s\n", 
               sleepEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               sleepEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
        printf("  Wakeup Events: %s%s%s\n\n", 
               wakeupEnabled ? ANSI_SUCCESS : ANSI_WARNING,
               wakeupEnabled ? "Enabled" : "Disabled",
               ANSI_RESET);
        
        printf("%s──────────────────────────────────────────────────────%s\n", ANSI_PRIMARY, ANSI_RESET);
        
        // MARK: - Set up screen lock/unlock notifications
        NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
        
        [center addObserverForName:@"com.apple.screenIsLocked" 
                            object:nil 
                             queue:nil 
                        usingBlock:^(NSNotification * _Nonnull notification) {
            colorLog(ANSI_PRIMARY, @"EVENT", @"Screen LOCKED", 
                  [NSString stringWithFormat:@"State: locked=YES, awake=%@", 
                  isSystemAwake ? @"YES" : @"NO"]);
            isScreenLocked = YES;
            updateMonitoringState();
        }];
        
        [center addObserverForName:@"com.apple.screenIsUnlocked" 
                            object:nil 
                             queue:nil 
                                        usingBlock:^(NSNotification * _Nonnull notification) {
            colorLog(ANSI_PRIMARY, @"EVENT", @"Screen UNLOCKED", 
                  [NSString stringWithFormat:@"State: locked=NO, awake=%@", 
                  isSystemAwake ? @"YES" : @"NO"]);
            isScreenLocked = NO;
            updateMonitoringState();
        }];
        
        // MARK: - Set up sleep/wake notifications using NSWorkspace
        NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
        
        [workspaceCenter addObserverForName:NSWorkspaceWillSleepNotification
                                     object:nil
                                      queue:nil
                                 usingBlock:^(NSNotification * _Nonnull note) {
            colorLog(ANSI_PRIMARY, @"EVENT", @"System SLEEP", 
                  [NSString stringWithFormat:@"State: locked=%@, awake=NO", 
                  isScreenLocked ? @"YES" : @"NO"]);
            isSystemAwake = NO;
            updateMonitoringState();
            
            // Execute sleep script
            executeSleepScript();
        }];
        
        [workspaceCenter addObserverForName:NSWorkspaceDidWakeNotification
                                     object:nil
                                      queue:nil
                                 usingBlock:^(NSNotification * _Nonnull note) {
            colorLog(ANSI_PRIMARY, @"EVENT", @"System WAKE", 
                  [NSString stringWithFormat:@"State: locked=%@, awake=YES", 
                  isScreenLocked ? @"YES" : @"NO"]);
            isSystemAwake = YES;
            updateMonitoringState();
            
            // Execute wakeup script
            executeWakeupScript();
        }];
        
        // Check initial screen lock state
        isScreenLocked = checkIfScreenIsLocked();
        updateMonitoringState();
        
        // Set up signal handling
        signal(SIGINT, handleSignal);
        signal(SIGTERM, handleSignal);
        
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}