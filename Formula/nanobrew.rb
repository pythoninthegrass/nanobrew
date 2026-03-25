class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.072"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.072/nb-arm64-apple-darwin.tar.gz"
      sha256 "9d03b8da6a6a634dc07a206b11dce0b1df0927ffb34b64e267298ecebb4579d6"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.072/nb-x86_64-apple-darwin.tar.gz"
      sha256 "28bfb9d04260631e1b685eada5b7f310db0330c22aef6df742fdfd2942f8b64e"
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
