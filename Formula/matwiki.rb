class Matwiki < Formula
  desc "Local-first mathematics and computational (.mw) notebook inside Neovim"
  homepage "https://github.com/DemirKucukdemiral/matWiki"
  url "https://github.com/DemirKucukdemiral/matWiki/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0d85c4270a09fa1d118902a456c4caafd34a56a809915f5c6261a8b8a3e755a2"
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
