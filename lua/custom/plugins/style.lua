-- [[ Styling ]]
--
-- The colorscheme itself lives in `init.lua` (search for `[[ Colorscheme ]]`).
-- This file holds the statusline.
--
-- Icons below are Nerd Font glyphs. If they ever render as tofu boxes (□),
-- either your terminal font isn't a Nerd Font or it's an old (pre-v3) one --
-- set `vim.g.have_nerd_font = false` in init.lua and the ASCII fallbacks
-- further down will be used instead.

local nerd = vim.g.have_nerd_font

vim.pack.add { 'https://github.com/nvim-lualine/lualine.nvim' }

-- Only show the mode name in the statusline, not also on the last line.
-- (init.lua already sets this, repeated here so this file stands alone.)
vim.o.showmode = false

-- A single global statusline for the whole window layout instead of one per
-- split. Keeps things calm when you have three windows open.
vim.o.laststatus = 3

--- Trim the mode down to a short, fixed-width label so the left edge of the
--- statusline doesn't jump around as you change modes.
local mode_map = {
  ['NORMAL'] = 'N',
  ['O-PENDING'] = 'N?',
  ['INSERT'] = 'I',
  ['VISUAL'] = 'V',
  ['V-BLOCK'] = 'VB',
  ['V-LINE'] = 'VL',
  ['V-REPLACE'] = 'VR',
  ['REPLACE'] = 'R',
  ['COMMAND'] = '!',
  ['SHELL'] = 'SH',
  ['TERMINAL'] = 'T',
  ['EX'] = 'X',
  ['S-BLOCK'] = 'SB',
  ['S-LINE'] = 'SL',
  ['SELECT'] = 'S',
  ['CONFIRM'] = '?',
  ['MORE'] = 'M',
}

--- Names of the LSP clients attached to the current buffer, e.g. `lua_ls`.
--- Shown on the right so you can tell at a glance whether the LSP actually
--- came up for this file.
local function lsp_clients()
  local clients = vim.lsp.get_clients { bufnr = 0 }
  if #clients == 0 then
    return ''
  end
  local names = {}
  for _, client in ipairs(clients) do
    table.insert(names, client.name)
  end
  return (nerd and '󰅴 ' or 'lsp:') .. table.concat(names, ',')
end

require('lualine').setup {
  options = {
    theme = 'auto', -- picks up rose-pine / gruvbox-material / everforest automatically
    icons_enabled = nerd,
    -- Powerline-style angled separators between sections, thin bars between
    -- components inside a section. Both need a Nerd Font.
    component_separators = nerd and { left = '', right = '' } or { left = '|', right = '|' },
    section_separators = nerd and { left = '', right = '' } or { left = '', right = '' },
    globalstatus = true,
    disabled_filetypes = {
      statusline = { 'neo-tree', 'NeogitStatus', 'alpha' },
    },
  },
  sections = {
    lualine_a = {
      {
        'mode',
        fmt = function(str) return mode_map[str] or str end,
      },
    },
    lualine_b = {
      { 'branch', icon = nerd and '' or 'git' },
      {
        'diff',
        symbols = nerd and { added = ' ', modified = ' ', removed = ' ' } or { added = '+', modified = '~', removed = '-' },
      },
    },
    lualine_c = {
      -- Path relative to the cwd, with modified/readonly flags.
      {
        'filename',
        path = 1,
        symbols = {
          modified = nerd and ' ' or ' [+]',
          readonly = nerd and ' ' or ' [RO]',
          unnamed = '[No Name]',
        },
      },
      {
        'diagnostics',
        sources = { 'nvim_diagnostic' },
        symbols = nerd and { error = ' ', warn = ' ', info = ' ', hint = ' ' } or { error = 'E', warn = 'W', info = 'I', hint = 'H' },
      },
    },
    lualine_x = {
      -- Only surface the encoding and line ending when they're *not* the
      -- boring defaults -- no point burning space on "utf-8 unix" forever.
      {
        'encoding',
        cond = function() return (vim.bo.fileencoding or '') ~= '' and vim.bo.fileencoding ~= 'utf-8' end,
      },
      {
        'fileformat',
        symbols = { unix = '', dos = 'CRLF', mac = 'CR' },
        cond = function() return vim.bo.fileformat ~= 'unix' end,
      },
      lsp_clients,
      { 'filetype', icon_only = nerd },
    },
    lualine_y = { 'progress' },
    lualine_z = {
      { 'location', padding = { left = 1, right = 1 } },
    },
  },
  -- No `inactive_sections` override: with globalstatus there is only ever one
  -- statusline, so the inactive variant never renders anyway.
  extensions = { 'neo-tree', 'quickfix', 'man' },
}
