if exists("b:current_syntax")
  finish
endif

if !exists("g:markdown_fenced_languages")
  let g:markdown_fenced_languages = ['python', 'lua', 'javascript', 'js=javascript', 'sh', 'bash=sh', 'tex', 'c', 'cpp', 'rust', 'go']
endif

runtime! syntax/markdown.vim
unlet! b:current_syntax

syn match mwDivFence /^\s*:::\+.*$/
syn match mwAttrs /{#\?[A-Za-z0-9_.:\-= "'#]\+}/
syn match mwRef /\(@\|\[@\)[A-Za-z][A-Za-z0-9_-]*:[A-Za-z0-9_.\-:]*[A-Za-z0-9_-]\]\?/
syn match mwWikiLink /\!\?\[\[[^\]]\+\]\]/
syn region mwFrontMatter start=/\%^---$/ end=/^\(---\|\.\.\.\)$/ keepend
syn region mwMathInline matchgroup=Delimiter start=/\$[^$ \t]/ skip=/\\\$/ end=/\$/ oneline
syn region mwMathDisplay matchgroup=Delimiter start=/\$\$/ end=/\$\$/ keepend
syn region mwOutputBlock matchgroup=Comment start=/^\s*```\+\s*\(output\|result\|results\)\>.*$/ end=/^\s*```\+\s*$/ keepend

hi def link mwDivFence PreProc
hi def link mwAttrs Special
hi def link mwRef Identifier
hi def link mwWikiLink Underlined
hi def link mwFrontMatter Comment
hi def link mwMathInline String
hi def link mwMathDisplay String
hi def link mwOutputBlock Comment

let b:current_syntax = "mw"
