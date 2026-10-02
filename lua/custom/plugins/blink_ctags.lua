-- blink.cmp completion source backed by the ctags "tags" file.
--
-- verible-verilog-ls advertises no completionProvider at all, and slang-server
-- only completes what its compilation can reach, so neither offers names from
-- files that are indexed but outside the current elaboration. The tags file
-- covers every file in verible.filelist, which makes it a useful third source
-- for module / typedef / macro / task names.
--
-- Regenerate the index with :VeribleCtags (<leader>vc) after adding files; this
-- source notices the new mtime and drops its cache.
--
-- Wired up in init.lua as the `ctags` provider for verilog + systemverilog.
-- Reads whatever 'tags' resolves to, which by default is the nearest `tags`
-- file at or above the current file -- exactly where :VeribleCtags writes it.

local Kind = require('blink.cmp.types').CompletionItemKind

--- Universal Ctags SystemVerilog kind letters (`ctags --list-kinds=SystemVerilog`)
--- to `{ lsp kind, readable name }`. Verilog's letters are a subset.
local KINDS = {
  A = { Kind.Event, 'assertion' },
  C = { Kind.Class, 'class' },
  E = { Kind.EnumMember, 'enumerator' },
  H = { Kind.Module, 'checker' },
  I = { Kind.Interface, 'interface' },
  K = { Kind.Module, 'package' },
  L = { Kind.Event, 'clocking' },
  M = { Kind.Interface, 'modport' },
  N = { Kind.Struct, 'nettype' },
  O = { Kind.Property, 'constraint' },
  P = { Kind.Module, 'program' },
  Q = { Kind.Function, 'prototype' },
  R = { Kind.Property, 'property' },
  S = { Kind.Struct, 'struct' },
  T = { Kind.Struct, 'typedef' },
  V = { Kind.Class, 'covergroup' },
  b = { Kind.Text, 'block' },
  c = { Kind.Constant, 'parameter' },
  d = { Kind.Constant, 'macro' },
  e = { Kind.Event, 'event' },
  f = { Kind.Function, 'function' },
  i = { Kind.Variable, 'instance' },
  l = { Kind.Class, 'interface class' },
  m = { Kind.Module, 'module' },
  n = { Kind.Variable, 'net' },
  p = { Kind.Field, 'port' },
  q = { Kind.Property, 'sequence' },
  r = { Kind.Variable, 'variable' },
  t = { Kind.Function, 'task' },
  w = { Kind.Field, 'member' },
}

--- Fields `taglist()` always returns; anything else is the scope, keyed by the
--- kind of the enclosing symbol (`module = "foo"`, `package = "pkg_p"`, ...).
local RESERVED = { name = true, filename = true, cmd = true, kind = true, static = true }

--- The declaration line ctags recorded, without the `/^...$/` search wrapper.
--- Empty for tags addressed by line number (`--excmd=number`).
---@param tag table
---@return string
local function declaration(tag)
  local cmd = tag.cmd or ''
  if cmd:match '^%d+$' then return '' end
  cmd = cmd:gsub('^/%^?', ''):gsub('%$?/$', ''):gsub('\\([\\/])', '%1')
  return vim.trim(cmd)
end

---@param tag table
---@return string|nil scope e.g. "module foo"
local function scope_of(tag)
  for key, value in pairs(tag) do
    if not RESERVED[key] and type(value) == 'string' and value ~= '' then return key .. ' ' .. value end
  end
end

---@param tags table[] `taglist()` output
---@param max integer
---@return blink.cmp.CompletionItem[]
local function to_items(tags, max)
  local counts = {}
  for _, tag in ipairs(tags) do
    if tag.name then counts[tag.name] = (counts[tag.name] or 0) + 1 end
  end

  local items, seen = {}, {}
  for _, tag in ipairs(tags) do
    local name = tag.name
    if name and name ~= '' and not seen[name] then
      seen[name] = true

      local letter = (tag.kind or ''):sub(1, 1)
      local kind = KINDS[letter] or { Kind.Text, letter ~= '' and letter or 'tag' }
      local file = vim.fn.fnamemodify(tag.filename or '', ':~:.')

      local footer = ('`%s`'):format(file)
      local scope = scope_of(tag)
      if scope then footer = footer .. ' - in ' .. scope end
      if counts[name] > 1 then footer = footer .. (' (+%d more)'):format(counts[name] - 1) end

      items[#items + 1] = {
        label = name,
        kind = kind[1],
        insertText = name,
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
        detail = kind[2] .. '  ' .. file,
        documentation = { kind = 'markdown', value = table.concat({ '```systemverilog', declaration(tag), '```', '', footer }, '\n') },
      }

      if #items >= max then break end
    end
  end
  return items
end

--- Tag files plus their mtimes: the cache key for the whole index.
---@return string
local function index_stamp()
  local parts = {}
  for _, file in ipairs(vim.fn.tagfiles()) do
    local stat = vim.uv.fs_stat(vim.fn.fnamemodify(file, ':p'))
    table.insert(parts, file .. ':' .. (stat and stat.mtime.sec or 0))
  end
  return table.concat(parts, ',')
end

---@class blink.cmp.CtagsOpts
---@field max_items integer Cap on items per keyword, before fuzzy matching.

---@class blink.cmp.CtagsSource : blink.cmp.Source
local Source = {}

---@param opts blink.cmp.CtagsOpts
function Source.new(opts)
  local self = setmetatable({}, { __index = Source })
  self.opts = vim.tbl_extend('keep', opts or {}, { max_items = 200 })
  self.cache = { stamp = '', items = {} }
  return self
end

function Source:enabled() return #vim.fn.tagfiles() > 0 end

---@param keyword string
---@return blink.cmp.CompletionItem[]
function Source:query(keyword)
  if keyword == '' then return {} end

  local stamp = index_stamp()
  if stamp ~= self.cache.stamp then self.cache = { stamp = stamp, items = {} } end
  if self.cache.items[keyword] then return self.cache.items[keyword] end

  -- `^`-anchored so vim binary-searches the sorted tags file instead of
  -- scanning it. `taglist()` throws on a malformed pattern, hence the pcall.
  local ok, tags = pcall(vim.fn.taglist, '^' .. vim.fn.escape(keyword, '\\^$.*~[]/'))
  local items = (ok and type(tags) == 'table') and to_items(tags, self.opts.max_items) or {}

  self.cache.items[keyword] = items
  return items
end

function Source:get_completions(ctx, callback)
  local keyword = ctx.line:sub(ctx.bounds.start_col, ctx.bounds.start_col + ctx.bounds.length - 1)
  callback {
    -- The query is anchored on the keyword, so blink must re-ask as it grows.
    is_incomplete_forward = true,
    is_incomplete_backward = true,
    items = self:query(keyword),
  }
end

return Source
