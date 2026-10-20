# Welcome to MatWiki

Your notes, mathematics, and experiments live here as ordinary files.

Press `i` to write and Escape to return to normal mode. Save with `:w`.
Press Space then `?` for the searchable command palette.

## Try a linked note

Put the cursor anywhere inside [[linear-algebra|Linear algebra]], then press
Space `no`. Go back with Ctrl-o. Space `nb` shows the notes linking here.

Use Space `nn` for a new Markdown note, Space `nx` for a full LaTeX note,
or Space `nd` for today's daily note. Space `nf` finds notes by name;
Space `ns` searches their contents. Links use `[[note-name]]` or
`[[folder/note-name|display text]]`.

## Write mathematics

Inline maths: $Ax = \lambda x$.

Display maths:

$$
\langle x,y\rangle = \sum_{i=1}^{n} x_i y_i.
$$

Space `ms` inserts a maths snippet; Tab moves between its fields.
For full LaTeX, open [[spectral-theorem.tex|the sample theorem]].
Space `mb` compiles a PDF. Space `mv` opens it. Space `mw` toggles
rebuilding when you save. Markdown PDF export also needs Pandoc.

The terminal edits maths source. The PDF viewer shows the fully typeset result.

## Run an experiment

Place the cursor in this block and press Space `rr`.

```python
from math import sqrt

# Eigenvalues of the symmetric matrix [[2, 1], [1, 2]].
a, b, d = 2, 1, 2
discriminant = sqrt((a - d)**2 + 4*b*b)
print("Eigenvalues:", (a + d - discriminant)/2, (a + d + discriminant)/2)
```

Space `re` edits this block in a Python buffer. `:w` writes it back to this
note's buffer; save the note afterward. Code runs only when you request it.
Each run starts a fresh process. Space `rt` opens an interactive terminal.

## Make it yours

Space `oc` opens `user.lua` for custom functions, snippets, runners, and keymaps.
Space `od` checks installed tools. Space `oh` opens the full guide.
Space `nh` returns to the dashboard.

Try the custom shortcut Space `ni` to create or reopen your Inbox.
