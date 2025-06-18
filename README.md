# LoginWatcher

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/RamanaRaj7/loginwatcher)

A lightweight macOS utility that monitors login attempts and triggers custom scripts on successful or failed authentication events and sleep and wake up events too like sleepwatcher.

## Features

- Monitors login attempts via TouchID and password
- Executes custom scripts on successful or failed login attempts
- Automatically starts at login and runs in the background
- Passes contextual information to scripts via environment variables
- Optimized to only monitor when screen is locked and system is awake

## Installation

### Using Homebrew

```bash
# Install from the tap
brew install ramanaraj7/tap/loginwatcher

# Start the service (runs in background)
brew services start loginwatcher
```

### Manual Installation

1. Clone the repository:
   ```
   git clone https://github.com/ramanaraj7/loginwatcher.git
   cd loginwatcher
   ```

2. Compile the application:
   ```
   clang -framework Foundation -framework AppKit -framework CoreGraphics loginwatcher.m -o loginwatcher
   ```

3. Copy the binary to a location in your PATH:
   ```
   cp loginwatcher /usr/local/bin/
   ```

4. Create a LaunchAgent to run at login:
   ```
   mkdir -p ~/Library/LaunchAgents
   cp homebrew.mxcl.loginwatcher.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/homebrew.mxcl.loginwatcher.plist
   ```

## Usage

### Setting Up Scripts

Create executable scripts in your home directory (to access this run 'nano ~/.filename'):

1. `~/.login_success` - Executed when login succeeds (via TouchID or password)
2. `~/.login_failure` - Executed when login fails (via TouchID or password)
3. `~/.sleep`         - Executed when system goes to sleep
4. `~/.wakeup`        - Executed when system wakes from sleep

Make sure both scripts are executable:

```bash
chmod +x ~/.login_success ~/.login_failure
```

### Environment Variables

The following environment variables are passed to your scripts:

- `AUTH_RESULT` - Either "SUCCESS" or "FAILED"
- `AUTH_METHOD` - Either "TouchID" or "Password"
- `TOTAL_FAILURES` - Total number of authentication failures since last success
- `TOUCHID_FAILURES` - Number of TouchID failures since last success
- `PASSWORD_FAILURES` - Number of password failures since last success

### Example Scripts

#### Success Script Example (~/.login_success)

```bash
#!/bin/bash

# Log the successful login
echo "[$(date)] Login SUCCESS via $AUTH_METHOD" >> ~/.login_events.log

# Other actions you might want to perform on successful login:
# - Start applications
# - Connect to VPN
# - Mount network drives
```

#### Failure Script Example (~/.login_failure)

```bash
#!/bin/bash

# Log the failed login attempt
echo "[$(date)] Login FAILED via $AUTH_METHOD (Total: $TOTAL_FAILURES)" >> ~/.login_events.log

# Other actions you might want to perform on failed login:
# - Send alerts
# - Take a screenshot or webcam photo
# - Play a sound
```

### Advanced: Conditional Script Execution Based on Failure Count

You can configure scripts to run only after specific failure thresholds are met. This is useful for implementing escalating responses to repeated login failures.

Add script configurations to your `~/.login_failure` file using one of these formats:

1. **Default (runs on first failure only):**
   ```
   ~/example.sh
   ```

2. **Run after specific failure counts:**
   ```
   ~/example.sh {method:count,method2:count2}
   ```

3. **Run on every failure:**
   ```
   ~/example.sh {everytime}
   ```

For example:

```bash
# Runs only on the first failure
~/notify.sh

# Runs on every failed login attempt
~/log_attempt.sh {everytime}

# Send notification after 2 total failures
~/notify.sh {total:2}

# Take screenshot after 3 password failures
~/take_photo.sh {password:3}

# Send email alert after 5 TouchID failures
~/send_email.sh {touchid:5}

# Multiple triggers for one script
~/alert.sh {total:3,touchid:2,password:4}
```

Available methods:
- `everytime` - Execute on every failed login attempt
- `total` - Total failures across both authentication methods
- `touchid` - TouchID-specific failures
- `password` - Password-specific failures

Each script will run exactly once when its threshold is reached (except for `everytime` scripts). All counters reset upon successful authentication.

### Running Python Scripts

You can run Python scripts from your login handlers by specifying the full path to the Python interpreter:

```bash
#!/bin/bash
/opt/homebrew/opt/python@3.11/bin/python3.11 /Users/username/example.py
```

**Important:** Some Python packages require accessibility permissions to function properly. To enable this:

1. Go to System Settings > Privacy & Security > Accessibility
2. Add the Python interpreter, Terminal and loginwatcher (path: /opt/homebrew/Cellar/loginwatcher/1.0.4/bin/loginwatcher) in application to the list of allowed apps

### Running Shell Scripts

You can also call other shell scripts from your login handlers:

```bash
#!/bin/bash
~/example.sh
```

Make sure any called scripts are also executable (`chmod +x ~/example.sh`).

## Command Line Options

```
Usage: loginwatcher [options]

Options:
  --version     Print version information and exit
  --help        Print this help message and exit
  --setup       Create example configuration files and scripts
  --config      Configure which scripts are enabled
  --monitor     Start monitoring for authentication events
```

## Requirements

- macOS 10.13 or later

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Security Considerations

This utility requires monitoring system logs which may contain sensitive information. All processing is done locally on your machine, and no data is sent to external servers.

To allow log access, you may need to grant Full Disk Access to the Terminal or application that launches loginwatcher.
