class Loginwatcher < Formula
  desc "Monitor macOS login attempts and trigger scripts on success/failure"
  homepage "https://github.com/RamanaRaj7/loginwatcher"
  url "https://github.com/RamanaRaj7/loginwatcher/archive/refs/tags/v1.0.2.tar.gz"
  sha256 "20372f640b57b374d1884e424d086e36e0171f9411c38da3572df69fdba9ccf9"
  license "MIT"

  depends_on :macos
  depends_on xcode: :build

  def install
    system "clang", "-framework", "Foundation", "-framework", "AppKit", "-framework", "CoreGraphics", "loginwatcher.m", "-o", "loginwatcher"
    bin.install "loginwatcher"

    # Create log directory
    (var/"log").mkpath
  end

  service do
    run opt_bin/"loginwatcher"
    keep_alive true
    log_path var/"log/loginwatcher.log"
    error_log_path var/"log/loginwatcher.log"
  end

  def caveats
    <<~EOS
      To use loginwatcher, create executable scripts in your home directory:
        ~/.login_success - run when login succeeds (via TouchID or password)
        ~/.login_failure - run when login fails (via TouchID or password)
      
      Environment variables passed to scripts:
        AUTH_TIMESTAMP - UTC timestamp of auth event
        AUTH_USER - your username
        AUTH_RESULT - "SUCCESS" or "FAILED" 
        AUTH_METHOD - "TouchID" or "Password"
        TOTAL_FAILURES - Total number of failures
        TOUCHID_FAILURES - Number of TouchID failures
        PASSWORD_FAILURES - Number of password failures
        
      Advanced Configuration:
        In ~/.login_failure, you can specify scripts with different behaviors:
        - Default (first failure only): ~/script.sh
        - Run after specific counts: ~/script.sh {method:count,...}
        - Run on every failure: ~/script.sh {everytime}
        
        Examples:
          ~/notify.sh                  # first failure only
          ~/log.sh {everytime}         # every failure
          ~/alert.sh {total:3}         # after 3 total failures
          ~/take_photo.sh {touchid:5}  # after 5 TouchID failures
          ~/send_email.sh {password:3} # after 3 password failures

      To run loginwatcher now and on login:
        brew services start loginwatcher
    EOS
  end

  test do
    system "#{bin}/loginwatcher", "--version"
  end
end 