class Matwiki < Formula
  desc "Local-first mathematics and computational (.mw) notebook inside Neovim"
  homepage "https://github.com/DemirKucukdemiral/matWiki"
  url "https://github.com/DemirKucukdemiral/matWiki/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "2b7ef8ff81b27eefa14572c532b83d8457b6fd30e3b5a34b3eabf6498ed6022d"
  license "MIT"
  head "https://github.com/DemirKucukdemiral/matWiki.git", branch: "main"

  depends_on "neovim"

  def install
    libexec.install Dir[
      "init.lua",
      "matwiki",
      "user.lua",
      "README.md",
      "assets",
      "doc",
      "ftdetect",
      "ftplugin",
      "lua",
      "notebook",
      "scripts",
      "syntax",
      "templates",
      "tests",
      "vendor"
    ]
    chmod 0755, libexec/"matwiki"
    bin.install_symlink libexec/"matwiki"
  end

  test do
    assert_match "MatWiki", shell_output("#{bin}/matwiki --help")
  end
end
