local has_telescope, telescope = pcall(require, "telescope")

-- TODO: make sure scandir unindexed have opts.ignore_patterns applied
-- TODO: make filters handle mulitple directories

if not has_telescope then
  error("This plugin requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)")
end

local actions       = require('telescope.actions')
local conf          = require('telescope.config').values
local entry_display = require "telescope.pickers.entry_display"
local finders       = require "telescope.finders"
local mappings      = require('telescope.mappings')
local path          = require('telescope.path')
local pickers       = require "telescope.pickers"
local sorters       = require "telescope.sorters"
local utils         = require('telescope.utils')
local db_client     = require("telescope._extensions.frecency.db_client")

local os_home       = vim.loop.os_homedir()
local os_path_sep   = utils.get_separator()

local state = {
  results         = {},
  active_filter   = nil,
  previous_buffer = nil,
  cwd             = nil,
  show_scores     = false,
  user_workspaces = {},
  lsp_workspaces  = {},
  picker    = {}
}

local function format_filepath(filename, opts)
  -- if state.show_filter_column and state.active_filter ~= nil then return filename end
  -- TODO: Not sure what which of these need to be optional
  local original_filename = filename

  if state.active_filter then
    filename = path.make_relative(filename, state.active_filter)
  else
    filename = path.make_relative(filename, state.cwd)
    -- check relative to home/current
    if vim.startswith(filename, os_home) then
      filename = "~/" ..  path.make_relative(filename, os_home)
    elseif filename ~= original_filename then
      filename = "./" .. filename
    end
  end

  if opts.tail_path then
    filename = utils.path_tail(filename)
  elseif opts.shorten_path then
    filename = utils.path_shorten(filename)
  end

  return filename
end

local function get_workspace_tags()
  -- TODO: validate that workspaces are existing directories
  local tags = {}
  for k,_ in pairs(state.user_workspaces) do
    table.insert(tags, k)
  end
  local lsp_workspaces = vim.api.nvim_buf_call(state.previous_buffer, vim.lsp.buf.list_workspace_folders)

  if not vim.tbl_isempty(lsp_workspaces) then
    state.lsp_workspaces = lsp_workspaces
    tags[#tags+1] = "LSP"
  else
    state.lsp_workspaces = {}
  end

  -- print(vim.inspect(tags))
  -- TODO: sort tags - by collective frecency?
  return tags
end

local frecency = function(opts)
  opts = opts or {}

  state.previous_buffer = vim.fn.bufnr('%')
  state.cwd = vim.fn.expand(opts.cwd or vim.fn.getcwd())

  local function get_display_cols()
    local directory_col_width = state.active_filter and #state.active_filter or 2
    local res = {}
    res[1] = state.show_scores and {width = 8} or nil
    if state.show_filter_column then
      table.insert(res, {width = directory_col_width})
    end
    table.insert(res, {remaining = true})
    return res
  end

  local displayer = entry_display.create {
    separator = "",
    hl_chars = {[os_path_sep] = "TelescopePathSeparator"},
    items = get_display_cols()
  }

  local bufnr, buf_is_loaded, filename, hl_filename, display_items
  local make_display = function(entry)
    bufnr = vim.fn.bufnr
    buf_is_loaded = vim.api.nvim_buf_is_loaded

    filename    = entry.name
    hl_filename = buf_is_loaded(bufnr(filename)) and "TelescopeBufferLoaded" or ""
    filename    = format_filepath(filename, opts)

    display_items = state.show_scores and {{entry.score, "TelescopeFrecencyScores"}} or {}

    local filter_path = state.active_filter and path.make_relative(state.active_filter, os_home) .. os_path_sep or ""
    table.insert(display_items, {filter_path, "Directory"})
    table.insert(display_items, {filename, hl_filename})

    return displayer(display_items)
  end

  local update_results = function(filter)
    local filter_updated = false

    -- validate tag
    local ws_dir = filter and state.user_workspaces[filter]
    if filter == "LSP" and not vim.tbl_isempty(state.lsp_workspaces) then
      ws_dir = state.lsp_workspaces[1]
    end

    if ws_dir ~= state.active_filter then -- TODO: updated needs to be triggered when we have no text?
      filter_updated = true
      state.active_filter = ws_dir
    end

    if vim.tbl_isempty(state.results) or filter_updated then
      state.results = db_client.get_file_scores(state.show_unindexed, ws_dir)
    end
    return filter_updated
  end

  -- populate initial results
  update_results()

  print(state.active_filter or "init")
  local entry_maker = function(entry)
    return {
      value   = entry.filename,
      display = make_display,
      ordinal = entry.filename,
      name    = entry.filename,
      score   = entry.score
    }
  end

    state.picker = pickers.new(opts, {
    prompt_title = "Frecency",
    on_input_filter_cb = function(query_text)
      local delim = opts.filter_delimiter or ":"
      -- check for :filter: in query text
      local new_filter = query_text:gmatch(delim .. "%S+" .. delim)()

      if new_filter then
        query_text = query_text:gsub(new_filter, "")
        new_filter = new_filter:gsub(delim, "")
      end

      local new_finder
      local results_updated = update_results(new_filter)
      if results_updated then
        new_finder = finders.new_table {
          prompt_title = "bar",
          results     = state.results,
          entry_maker = entry_maker
        }
      end

      return query_text, new_finder
    end,
    attach_mappings = function(prompt_bufnr)
      actions.goto_file_selection_edit:replace(function()
        local compinfo = vim.fn.complete_info()
        if compinfo.pum_visible == 1 then
          local keys = compinfo.selected == -1 and "<C-e><Bs><Right>" or "<C-y><Right>:"
          local accept_completion = vim.api.nvim_replace_termcodes(keys, true, false, true)
          vim.fn.nvim_feedkeys(accept_completion, "n", true)
        else
          actions._goto_file_selection(prompt_bufnr, "edit")
        end
      end)

      return true
    end,
    finder = finders.new_table {
      results     = state.results,
      entry_maker = entry_maker
    },
    previewer = conf.file_previewer(opts),
    sorter    = sorters.get_substr_matcher(opts),
  })
  -- state.picker.prompt_title = state.active_filter or vim.fn.getcwd()
  -- print(vim.inspect(picker))
  state.picker:find()

  local restore_vim_maps = {}
  restore_vim_maps.i = {
    ['<C-x>'] = "<C-x>",
    ['<C-u>'] = "<C-u>"
  }
  mappings.apply_keymap(state.picker.prompt_bufnr, mappings.attach_mappings, restore_vim_maps)

  vim.api.nvim_buf_set_option(state.picker.prompt_bufnr, "filetype", "frecency")
  vim.api.nvim_buf_set_option(state.picker.prompt_bufnr, "completefunc", "frecency#FrecencyComplete")
  vim.api.nvim_buf_set_keymap(state.picker.prompt_bufnr, "i", "<Tab>", "pumvisible() ? '<C-n>'  : '<C-x><C-u>'", {expr = true, noremap = true})
  -- vim.api.nvim_buf_set_keymap(state.picker.prompt_bufnr, "i", "<Tab>", [[<C-\\><C-o>:call feedkeys({-> return pumvisible() ? "<C-n>" : "<C-x><C-u>"}, 't')]], {expr = false, noremap = true})
end


return telescope.register_extension {
  setup = function(ext_config)
    state.show_scores         = ext_config.show_scores == nil and false or ext_config.show_scores
    state.show_unindexed      = ext_config.show_unindexed == nil and true or ext_config.show_unindexed
    state.show_filter_column  = ext_config.show_filter_column or true
    state.user_workspaces     = ext_config.workspaces or {}

    -- start the database client
    db_client.init(ext_config.ignore_patterns)
  end,
  exports = {
    frecency           = frecency,
    get_workspace_tags = get_workspace_tags,
  },
}
