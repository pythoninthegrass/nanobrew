class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.070"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.070/nb-arm64-apple-darwin.tar.gz"
      sha256 "a39860fddace47a7dd7d41958e4bc201774860c63b47d42c4c2edaa1d305b512"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.070/nb-x86_64-apple-darwin.tar.gz"
      sha256 "c2878db3529cf3664c6474e8544cdd561d8dc7ee2b1c64c72a8a2be21bb1ae4f"
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
