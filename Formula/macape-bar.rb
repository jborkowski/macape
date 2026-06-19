class MacapeBar < Formula
  desc "Menu bar controller for macape"
  homepage "https://github.com/jborkowski/macape"
  license "MIT"
  head "https://github.com/jborkowski/macape.git", branch: "main"

  depends_on xcode: ["14.0", :build]
  depends_on :macos
  depends_on "jborkowski/macape/macape"

  def install
    buildpath.cd do
      system "swift", "build",
             "--configuration", "release",
             "--disable-sandbox",
             "--product", "macape-bar",
             "-Xswiftc", "-Osize"
      bin.install ".build/release/macape-bar"
    end
  end

  service do
    run [opt_bin/"macape-bar"]
    keep_alive true
    log_path var/"log/macape-bar.log"
    error_log_path var/"log/macape-bar.log"
  end

  test do
    assert_predicate bin/"macape-bar", :exist?
  end
end
