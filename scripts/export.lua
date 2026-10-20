-- Headless CLI entry point for `./matwiki --export` and `./matwiki --export-all`.
local root = vim.env.MATWIKI_HOME or vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local mw = require('matwiki.mw')
local vault = vim.env.MATWIKI_VAULT or (root .. '/notebook')
mw.config = { root = root, vault = vault }

local args = _G.arg or {}
local mode = args[1]

if mode == '--all' then
  local out_dir = args[2] and vim.fn.fnamemodify(args[2], ':p') or (vault .. '/.site')
  local res = mw.export_vault({
    vault = vault,
    matwiki_root = root,
    out_dir = out_dir,
  })
  io.stdout:write(string.format('Exported %d notes -> %s (%.2f ms)\n', res.count, res.index, res.elapsed_ms))
  os.exit(0)
elseif mode == '--single' then
  local src = args[2]
  if not src or src == '' then
    io.stderr:write('Usage: matwiki --export <file.mw> [-o output.html] [--standalone]\n')
    os.exit(2)
  end
  local dst
  local standalone = false
  local i = 3
  while i <= #args do
    if args[i] == '-o' or args[i] == '--output' then
      dst = args[i + 1]
      i = i + 2
    elseif args[i] == '--standalone' then
      standalone = true
      i = i + 1
    else
      dst = dst or args[i]
      i = i + 1
    end
  end
  local res, err = mw.compile_file(src, dst, {
    vault = vault,
    matwiki_root = root,
    standalone = standalone,
  })
  if not res then
    io.stderr:write('Error: ' .. tostring(err) .. '\n')
    os.exit(1)
  end
  io.stdout:write(string.format('Compiled %s -> %s (%.2f ms)\n', res.source, res.output, res.elapsed_ms))
  os.exit(0)
else
  io.stderr:write('Unknown export mode: ' .. tostring(mode) .. '\n')
  os.exit(2)
end
