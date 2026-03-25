class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.073"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.073/nb-arm64-apple-darwin.tar.gz"
      sha256 "9c3c0a41dc91846bc19e343374a6f647ed17f700ef6ef17bcddf2f7e1d885896"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.073/nb-x86_64-apple-darwin.tar.gz"
      sha256 "dcd8ee60d2c2a5cd0c5e25a2f130cae91e3823e1c1c8de58b9b248059bb4db29"
    end
  end

  def install
    bin.install "nb"
  end

  def post_install
    ohai "Run 'nb init' to create the nanobrew directory tree"
  end

  test do
    assert_match "nanobrew", shell_output("#{bin}/nb help")
  end
end
