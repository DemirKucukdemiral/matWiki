-- Buffer-local enhancements for .mw files: output folding and virtual badges.
vim.wo.wrap = true
vim.wo.linebreak = true

local ns = vim.api.nvim_create_namespace('matwiki.mw.decor')
local B = require('matwiki.mw.block')

local function decorate(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cell_n, thm_n = 0, 0
  for i, line in ipairs(lines) do
    local colons, rest = line:match('^ ? ? ?(:::+)%s*(.-)%s*$')
    if colons and rest ~= '' and not rest:find('^:+$') then
      local name = (rest:match('^([%w_-]+)') or ''):lower()
      local env = B.ENVS[name]
      if env then
        local badge
        if env[3] then
          thm_n = thm_n + 1
          badge = string.format('  ◆ %s %d', env[1], thm_n)
        else
          badge = string.format('  ◇ %s', env[1])
        end
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          virt_text = { { badge, 'MatwikiKey' } },
          virt_text_pos = 'eol',
        })
      end
    else
      local f = B._fence_open(line)
      if f and f.info ~= '' then
        local lang = (f.info:match('^([%w_+%-%.#]+)') or ''):lower()
        if lang == 'output' or lang == 'result' or lang == 'results' then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
            virt_text = { { string.format('  ↳ Out [%d]', math.max(1, cell_n)), 'MatwikiDim' } },
            virt_text_pos = 'eol',
          })
        elseif B.RUNNABLE[lang] then
          cell_n = cell_n + 1
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
            virt_text = { { string.format('  ▶ In [%d] (%s)', cell_n, lang), 'MatwikiKey' } },
            virt_text_pos = 'eol',
          })
        end
      end
    end
  end
end

decorate(0)
vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'InsertLeave' }, {
  buffer = 0,
  callback = function(ev) decorate(ev.buf) end,
})
