class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.070"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.070/nb-arm64-apple-darwin.tar.gz"
      sha256 "e9ab798ede72666512a46b653048ea37678e39256302e2188b8dd8b2d63aed9e"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.070/nb-x86_64-apple-darwin.tar.gz"
      sha256 "ba4181ec4a0b9daec0ad2d1b99397ffface07f2609f7abfeaa848a457d9b1dd6"
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
