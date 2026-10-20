# MatWiki

MatWiki is a fast, local-first mathematics and computational notebook inside Neovim. It supports **`.mw` (MatWiki)** notes—combining Markdown prose, numbered LaTeX equations and theorem environments, `[[wiki-links]]`, and Jupyter-style executable code cells—alongside standard `.md` and `.tex` files, and compiles `.mw` / `.md` notes to offline HTML + CSS in milliseconds.

## Quick Start

```sh
./matwiki                                  # Open the MatWiki dashboard in Neovim
./matwiki notebook/spectral-workbench.mw   # Open the sample .mw notebook
./matwiki --export notebook/spectral-workbench.mw
./matwiki --export notebook/spectral-workbench.mw --standalone
./matwiki --export-all                     # Build the entire notebook to notebook/.site/index.html
./matwiki --doctor                         # Check installed optional tools
./matwiki --test                           # Run the headless test suites
```

 MatWiki keeps all Neovim state in `.state/` beside the launcher and never modifies `~/.config/nvim`.

## Essential Shortcuts (`Space` is leader)

| Keymap | Command | Action |
| :--- | :--- | :--- |
| `Space ?` | `:MatwikiCommands` | Searchable command palette |
| `Space nw` | `:MatwikiMw` | Create or open a `.mw` note |
| `Space nn` | `:MatwikiNew` | Create or open a Markdown (`.md`) note |
| `Space nx` | `:MatwikiTex` | Create or open a LaTeX (`.tex`) note |
| `Space nd` | `:MatwikiDaily` | Open today's daily note |
| `Space nf` | `:MatwikiFind` | Fuzzy-find a note in the vault |
| `Space ns` | `:MatwikiSearch` | Search note contents |
| `Space no` | `:MatwikiFollow` | Follow `[[wiki-link]]` under cursor |
| `Space nl` | `:MatwikiLink` | Insert a `[[wiki-link]]` |
| `Space nb` | `:MatwikiBacklinks` | Show notes linking to the current note |
| `Space mp` | `:MatwikiPreview` | Start live HTML + CSS preview in browser (hot-reloads on edit/save/run) |
| `Space me` | `:MatwikiExport` | Compile current `.mw`/`.md` note to HTML + CSS (`:MatwikiExport!` for single-file standalone) |
| `Space mE` | `:MatwikiExportVault` | Compile the entire vault into a linked HTML site (`notebook/.site/index.html`) |
| `Space rr` | `:MatwikiRun` | Run current code cell (updates ```` ```output ```` block in `.mw` notes) |
| `Space ra` | `:MatwikiRunAll` | Run all cells in the current note sequentially |
| `Space rc` | `:MatwikiClearOutputs` | Clear all ```` ```output ```` blocks in the current note |
| `Space rk` | `:MatwikiKernelRestart` | Restart persistent Python/Node kernel session |
| `Space re` | `:MatwikiEditBlock` | Edit current code block in a dedicated LSP-enabled language buffer |
| `Space mb` | `:MatwikiBuild` | Build PDF (`latexmk` for `.tex`, `pandoc` for `.md`) |
| `Space mv` | `:MatwikiView` | View compiled PDF |
| `Space ms` | `:MatwikiSnippet` | Insert a LaTeX math snippet |
| `Space oc` | `:MatwikiConfig` | Edit `user.lua` configuration |
| `Space od` | `:MatwikiDoctor` | Check installed tools and language servers |

## The `.mw` Format

See [`doc/mw-spec.md`](doc/mw-spec.md) for the complete `.mw` format specification, including YAML front matter, custom LaTeX macros, numbered equations (`{#eq:id}`), theorem/proof environments (`::: theorem`, `::: proof`), cross-references (`@thm:id`, `@eq:id`, `@fig:id`, `@tbl:id`, `@cell:id`), and persistent code cells.
