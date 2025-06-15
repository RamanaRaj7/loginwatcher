class Loginwatcher < Formula
  desc "Monitor macOS login attempts and trigger scripts on success/failure"
  homepage "https://github.com/RamanaRaj7/loginwatcher"
  url "https://github.com/RamanaRaj7/loginwatcher/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "5c9aabdd9bd00ae730b5393324da8d963563c4c1689c65c282ba18545403c8ac"
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

      To run loginwatcher now and on login:
        brew services start loginwatcher
    EOS
  end

  test do
    system "#{bin}/loginwatcher", "--version"
  end
end 