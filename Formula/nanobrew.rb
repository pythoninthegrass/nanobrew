class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.083"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.083/nb-arm64-apple-darwin.tar.gz"
      sha256 "00da0837346514726742574930c44cefb5dea2d44ba33624d7f8a2bccbc1c4a4"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.083/nb-x86_64-apple-darwin.tar.gz"
      sha256 "4aa4e3e7844c953a8226a1fd3fe49916ca84e78daf90990e4cf44d3434fdc2eb"
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
