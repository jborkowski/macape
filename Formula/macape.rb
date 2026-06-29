class Macape < Formula
  desc "Reliable home-row modifiers daemon for macOS"
  homepage "https://github.com/jborkowski/macape"
  license "MIT"
  head "https://github.com/jborkowski/macape.git", branch: "main"

  depends_on xcode: ["14.0", :build]
  depends_on :macos

  def install
    buildpath.cd do
      system "swift", "build",
             "--configuration", "release",
             "--disable-sandbox",
             "--product", "macape",
             "-Xswiftc", "-Osize"
      bin.install ".build/release/macape"
    end

    (etc/"macape").mkpath
    pkgshare.install "macape.conf.example"
    target = etc/"macape/macape.conf.example"
    target.atomic_write(File.read(pkgshare/"macape.conf.example")) unless target.exist?
  end

  def caveats
    <<~EOS
      First-time setup:

      1. Copy the example config:
           mkdir -p ~/.config/macape
           cp #{etc}/macape/macape.conf.example ~/.config/macape/macape.conf

      2. Grant Accessibility in:
           System Settings > Privacy & Security > Accessibility
         Add this binary:
           #{opt_bin}/macape

      3. Start the daemon:
           brew services start macape

      4. (Optional) Menu-bar controller:
           brew install jborkowski/macape/macape-bar
           brew services start macape-bar

      IPC socket: ~/.config/macape/macape.sock
      Stats: macape --stats
    EOS
  end

  service do
    run [opt_bin/"macape"]
    keep_alive true
    log_path var/"log/macape.log"
    error_log_path var/"log/macape.log"
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/macape --help")
  end
end
