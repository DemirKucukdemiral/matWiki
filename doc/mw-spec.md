# The `.mw` File Format Specification

`.mw` (**MatWiki**) is a plain-text, terminal-friendly superset of Markdown designed for writing mathematical notes and running Jupyter-style code cells inside Neovim, with sub-5ms compilation to offline HTML + CSS.

## 1. Front Matter

Optional YAML front matter at the top of the file between `---` fences:

```yaml
---
title: Spectral Theorem Workbench
subtitle: Optional subtitle
author: Your Name
date: 2026-10-20
kernel: python
number-sections: true
toc: true
tags: [linear-algebra, spectral-theory]
macros:
  \Sym: "\\operatorname{Sym}_n(\\mathbb{R})"
abstract: |
  Summary paragraph rendered in an abstract box.
---
```

Built-in LaTeX macros available in every `.mw` document (overridable via `macros`):
`\R`, `\N`, `\Z`, `\Q`, `\C`, `\F`, `\E`, `\P`, `\eps`, `\inner{a}{b}`, `\norm{x}`, `\abs{x}`, `\set{x}`, `\dd`.

## 2. Mathematics & Equation Numbering

- **Inline math**: `$Ax = \lambda x$` or `\(Ax = \lambda x\)`.
- **Display math**:
  - `$$ ... $$` or `\[ ... \]`
  - LaTeX environments: `\begin{equation}...\end{equation}`, `\begin{align}...\end{align}`, `\begin{gather}...\end{gather}`, `\begin{aligned}...\end{aligned}`.
- **Numbering & labels**:
  Add `{#eq:name}` after `$$` or `\label{eq:name}` inside a display environment. Numbered equations receive sequential `(1)`, `(2)` badges on the right margin and can be referenced anywhere with `@eq:name`, `[@eq:name]`, `\ref{eq:name}`, or `\eqref{eq:name}`.

## 3. Theorems, Proofs & Callouts

Fenced `:::` divs create structured environments:

```markdown
::: theorem {#thm:spectral title="Spectral Theorem"}
Every real symmetric matrix $A \in \R^{n\times n}$ is orthogonally diagonalisable.
:::

::: proof
By induction on $n$ using @eq:selfadj.
:::
```

- **Numbered environments** (share a sequential document counter `Theorem 1`, `Lemma 2`, `Definition 3`, unless `.unnumbered` or `numbered=false` is set):
  `theorem`, `lemma`, `proposition`, `corollary`, `conjecture`, `claim`, `axiom`, `hypothesis`, `definition`, `example`, `exercise`, `problem`, `question`, `algorithm`.
- **Unnumbered mathematical blocks**: `remark`, `observation`, `intuition`, `proof`, `solution` (renders a right-aligned `∎` QED tombstone).
- **Callouts**: `note`, `tip`, `important`, `warning`, `caution`, `info`, `todo`, `summary` (also supported via GitHub-style `> [!NOTE]` blockquotes).
- **Collapsible blocks**: `::: details {title="Derivation" open=false}`.

## 4. Executable Code Cells & Inline Outputs

Any fenced code block in a runnable language (`python`, `javascript`/`js`/`node`, `lua`, `bash`/`sh`, `julia`, `r`) is treated as a notebook cell:

````markdown
```python {#cell:eig echo=true output=show session=default}
A = [[2, 1], [1, 2]]
[sum(row) for row in A]
```
```output {of=cell:eig}
[3, 3]
```
````

### Cell Attributes
- `#cell:id`: optional anchor for `@cell:id` cross-references.
- `echo=true|false|fold`: show code (default), hide code (`echo=false`), or collapse code into a `<details>` toggle (`echo=fold`).
- `output=show|hide|fold`: show output (default), hide output (`output=hide`), or fold output (`output=fold`).
- `run=auto|manual|never`: `run=never` treats the block as a static code listing rather than a numbered cell; `run=manual` skips the cell during `:MatwikiRunAll`.
- `session=<name>|none`: Python and Node cells share a persistent kernel process per buffer (or named `session`). Set `session=none` to run in an isolated one-shot process.

### Output Blocks
- Pressing `Space rr` (`:MatwikiRun`) or `Space ra` (`:MatwikiRunAll`) executes the cell and writes/updates the ```` ```output ```` fence immediately below the cell in the `.mw` buffer.
- In Python cells, the value of the final expression is automatically printed via `repr()`, and `matplotlib.pyplot.show()` automatically saves figures to `<note>.assets/cell-<n>.png` and embeds `![figure](<note>.assets/cell-<n>.png)` inside the `output` block.

## 5. Wiki Links, Figures & Tables

- **Wiki links**: `[[note-name]]`, `[[folder/note#heading|Display text]]` resolve across `.mw`, `.md`, and `.tex` notes in the vault and compile to relative `.html` links with automatic backlinks at the bottom of each page.
- **Figures**: standalone image paragraphs `![Caption text](path/to/img.png){#fig:name width=480}` compile to `<figure>` with numbered `Figure 1:` captions and `@fig:name` references.
- **Tables**: pipe tables followed by `: Caption text {#tbl:name}` receive numbered `Table 1:` captions and `@tbl:name` references.
