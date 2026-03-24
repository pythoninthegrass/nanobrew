class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.069"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.069/nb-arm64-apple-darwin.tar.gz"
      sha256 "acb64143c295f2ef6fac821d76f6210d770f65cd83847f01d6b9d5054cff168a"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.069/nb-x86_64-apple-darwin.tar.gz"
      sha256 "07119f57f63588d9e78be46a5930f560e775db7d5de0d7c1092d4062bf20134c"
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
