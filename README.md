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
| `Space ng` | `:MatwikiFolder` | Create or open a folder, including nested folders |
| `Space nd` | `:MatwikiDaily` | Open today's daily note |
| `Space nf` | `:MatwikiFind` | Fuzzy-find a note in the vault |
| `Space ns` | `:MatwikiSearch` | Search note contents |
| `Space no` | `:MatwikiFollow` | Follow `[[wiki-link]]` under cursor |
| `Space nl` | `:MatwikiLink` | Choose an existing note or create and link a new one |
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

## Folders and links

Press `Space ng` (or `g` on the dashboard) and enter `Research/Control` to create and browse that folder. Press `Space nw` to create a `.mw` note: the prompt starts in the current folder. You can also create a note and all its parent folders in one command:

```vim
:MatwikiMw Research/Control/Linear Systems
:MatwikiNew Research/Reading list
:MatwikiTex Research/Proofs/Stability
```

These paths are relative to your vault. Folder names are preserved; the final note name becomes a filename such as `Research/Control/linear-systems.mw`. Supplying the matching extension is optional. Existing notes open without being overwritten.

Press `Space nl` to search existing notes or select **Create and link a new note…**. Creating a destination keeps your current note open and inserts its link. You can also give a destination directly:

```vim
:MatwikiLink Research/Control/linear-systems.mw
:MatwikiLink Research/Control/linear-systems.mw#Notes|Linear systems
```

Put the cursor inside a `[[link]]` and press `Space no` to follow it. Missing notes offer a create option. Use `Space nb` to find backlinks. Bare names such as `[[stability]]` offer a choice when multiple notes match; an explicit path or filename uses the vault root first. Links inserted by the picker include the extension to avoid name collisions. Hidden, build, code, and `.assets` folders are excluded from the note index.

## Requirements and customization

The standalone launcher requires Neovim 0.12.4 or newer on Linux or macOS. It bundles VimTeX, KaTeX, and syntax highlighting; no plugins download at startup. Run `./matwiki --doctor` to see what is available on your machine.

- `.tex` PDF builds use `latexmk` and a TeX engine; Markdown PDF builds additionally need Pandoc. `.mw` notes export to HTML, including standalone HTML.
- Python and JavaScript cells need Python 3 and Node.js respectively. Python plotting additionally needs `matplotlib` in the Python environment used by MatWiki. Other cell languages need their interpreters.
- Language-server completion and diagnostics require the corresponding optional server. Ordinary editing, navigation, and snippets work without them.

Open `Space oc` to customize `user.lua`: your vault, PDF viewer and engine, runners, snippets, language servers, and `after_setup` commands or keymaps. Restart MatWiki after configuration changes. `lsp = { texlab = false }` disables that server. Explicit custom Python/Node runners use one-shot execution; default Python/Node runners support persistent notebook sessions.
