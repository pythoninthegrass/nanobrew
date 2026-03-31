class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.079"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.079/nb-arm64-apple-darwin.tar.gz"
      sha256 "2fa283162f2cd3b0396f8223e92d21d76c505effa65ba5d8980ebc5b5d68141f"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.079/nb-x86_64-apple-darwin.tar.gz"
      sha256 "ba19c90d0ca77cd79df85ebb22287a81e31fa48c4e3562212d750692d8a209f3"
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
