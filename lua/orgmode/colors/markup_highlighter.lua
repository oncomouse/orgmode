local config = require('orgmode.config')
local ts_utils = require('nvim-treesitter.ts_utils')
local query = nil

local valid_pre_marker_chars = { ' ', '(', '-', "'", '"', '{', '*', '/', '_', '+' }
local valid_post_marker_chars =
  { ' ', ')', '-', '}', '"', "'", ':', ';', '!', '\\', '[', ',', '.', '?', '*', '/', '_', '+' }

local markers = {
  ['*'] = {
    hl_name = 'org_bold',
    hl_cmd = 'hi def %s term=bold cterm=bold gui=bold',
    delimiter_hl = true,
    nestable = true,
    type = 'text',
  },
  ['/'] = {
    hl_name = 'org_italic',
    hl_cmd = 'hi def %s term=italic cterm=italic gui=italic',
    delimiter_hl = true,
    nestable = true,
    type = 'text',
  },
  ['_'] = {
    hl_name = 'org_underline',
    hl_cmd = 'hi def %s term=underline cterm=underline gui=underline',
    delimiter_hl = true,
    nestable = true,
    type = 'text',
  },
  ['+'] = {
    hl_name = 'org_strikethrough',
    hl_cmd = 'hi def %s term=strikethrough cterm=strikethrough gui=strikethrough',
    delimiter_hl = true,
    nestable = true,
    type = 'text',
  },
  ['~'] = {
    hl_name = 'org_code',
    hl_cmd = 'hi def link %s String',
    delimiter_hl = true,
    nestable = false,
    spell = false,
    type = 'text',
  },
  ['='] = {
    hl_name = 'org_verbatim',
    hl_cmd = 'hi def link %s String',
    delimiter_hl = true,
    nestable = false,
    spell = false,
    type = 'text',
  },
  ['\\('] = {
    hl_name = 'org_latex',
    hl_cmd = 'hi def link %s OrgTSLatex',
    nestable = false,
    spell = false,
    delimiter_hl = false,
    type = 'latex',
  },
  ['\\{'] = {
    hl_name = 'org_latex',
    hl_cmd = 'hi def link %s OrgTSLatex',
    nestable = false,
    delimiter_hl = false,
    type = 'latex',
  },
  ['\\s'] = {
    hl_name = 'org_latex',
    hl_cmd = 'hi def link %s OrgTSLatex',
    nestable = false,
    delimiter_hl = false,
    type = 'latex',
  },
}

---@param node userdata
---@param source number
---@param offset_col_start? number
---@param offset_col_end? number
---@return string
local function get_node_text(node, source, offset_col_start, offset_col_end)
  local start_row, start_col = node:start()
  local end_row, end_col = node:end_()
  start_col = start_col + (offset_col_start or 0)
  end_col = end_col + (offset_col_end or 0)

  local lines
  local eof_row = vim.api.nvim_buf_line_count(source)
  if start_row >= eof_row then
    return ''
  end

  if end_col == 0 then
    lines = vim.api.nvim_buf_get_lines(source, start_row, end_row, true)
    end_col = -1
  else
    lines = vim.api.nvim_buf_get_lines(source, start_row, end_row + 1, true)
  end

  if #lines > 0 then
    if #lines == 1 then
      lines[1] = string.sub(lines[1], start_col + 1, end_col)
    else
      lines[1] = string.sub(lines[1], start_col + 1)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
  end

  return table.concat(lines, '\n')
end

local get_tree = ts_utils.memoize_by_buf_tick(function(bufnr)
  local tree = vim.treesitter.get_parser(bufnr, 'org'):parse()
  if not tree or not #tree then
    return nil
  end
  return tree[1]:root()
end)

local function is_valid_markup_range(match, _, source, predicates)
  local start_node = match[predicates[2]]
  local end_node = match[predicates[3]]

  if not start_node or not end_node then
    return
  end

  local start_line = start_node:range()
  local end_line = end_node:range()

  if start_line ~= end_line then
    return false
  end

  local start_text = get_node_text(start_node, source, -1, 1)
  local start_len = start_text:len()

  local is_valid_start = (start_len < 3 or vim.tbl_contains(valid_pre_marker_chars, start_text:sub(1, 1)))
    and start_text:sub(start_len, start_len) ~= ' '
  if not is_valid_start then
    return false
  end
  local end_text = get_node_text(end_node, source, -1, 1)
  return (end_text:len() < 3 or vim.tbl_contains(valid_post_marker_chars, end_text:sub(3, 3)))
    and end_text:sub(1, 1) ~= ' '
end

local function is_valid_hyperlink_range(match, _, source, predicates)
  local start_node = match[predicates[2]]
  local end_node = match[predicates[3]]

  if not start_node or not end_node then
    return
  end

  local start_line = start_node:range()
  local end_line = start_node:range()

  if start_line ~= end_line then
    return false
  end

  local start_text = get_node_text(start_node, source, 0, 1)
  local end_text = get_node_text(end_node, source, -1)

  local is_valid_start = start_text == '[['
  local is_valid_end = end_text == ']]'
  return is_valid_start and is_valid_end
end

local function is_valid_latex_range(match, _, source, predicates)
  local start_node_left = match[predicates[2]]
  local start_node_right = match[predicates[3]]
  local end_node = match[predicates[4]]
  if not start_node_right or not end_node then
    return
  end

  local start_line = start_node_left:range()
  local start_line_right = start_node_right:range()
  local end_line = end_node:range()

  if start_line ~= start_line_right or start_line ~= end_line then
    return false
  end

  local _, start_left_col_end = start_node_left:end_()
  local _, start_right_col_end = start_node_right:end_()
  local start_text = get_node_text(start_node_left, source, 0, start_right_col_end - start_left_col_end)

  if start_text == '\\(' then
    local end_text = get_node_text(end_node, source, -1, 0)
    if end_text == '\\)' then
      return true
    end
  else
    -- we have to deal with two cases here either \foo{bar} or \bar
    local char_after_start = get_node_text(start_node_right, source, 0, 1):sub(-1)
    local end_text = get_node_text(end_node, source, 0, 0)
    -- if \foo{bar}
    if char_after_start == '{' and end_text == '}' then
      return true
    end
    -- elseif \bar
    if not start_text:sub(2):match('%A') and end_text ~= '}' then
      return true
    end
  end
  return false
end

local function load_deps()
  -- Already defined
  if query then
    return
  end
  query = vim.treesitter.query.get('org', 'markup')
  vim.treesitter.query.add_predicate('org-is-valid-markup-range?', is_valid_markup_range)
  vim.treesitter.query.add_predicate('org-is-valid-hyperlink-range?', is_valid_hyperlink_range)
  vim.treesitter.query.add_predicate('org-is-valid-latex-range?', is_valid_latex_range)
end

---@param bufnr number
---@param line_index number
---@return table
local get_matches = ts_utils.memoize_by_buf_tick(function(bufnr, line_index, root)
  local ranges = {}
  local taken_locations = {}

  for _, match, _ in query:iter_matches(root, bufnr, line_index, line_index + 1) do
    for _, node in pairs(match) do
      local char = node:type()
      -- saves unnecessary parsing, since \\ is not used below
      if char ~= '\\' then
        local range = ts_utils.node_to_lsp_range(node)
        local linenr = tostring(range.start.line)
        taken_locations[linenr] = taken_locations[linenr] or {}
        if not taken_locations[linenr][range.start.character] then
          table.insert(ranges, {
            type = char,
            range = range,
            node = node,
          })
          taken_locations[linenr][range.start.character] = true
        end
      end
    end
  end

  table.sort(ranges, function(a, b)
    if a.range.start.line == b.range.start.line then
      return a.range.start.character < b.range.start.character
    end
    return a.range.start.line < b.range.start.line
  end)

  local seek = {}
  local seek_link = {}
  local result = {}
  local link_result = {}
  local latex_result = {}

  local nested = {}
  local can_nest = true

  local type_map = {
    ['('] = '\\(',
    [')'] = '\\(',
    ['}'] = '\\{',
  }

  for _, item in ipairs(ranges) do
    if item.type == '(' then
      item.range.start.character = item.range.start.character - 1
    elseif item.type == 'str' then
      item.range.start.character = item.range.start.character - 1
      local char = get_node_text(item.node, bufnr, 0, 1):sub(-1)
      if char == '{' then
        item.type = '\\{'
      else
        item.type = '\\s'
      end
    end

    item.type = type_map[item.type] or item.type

    if markers[item.type] then
      if seek[item.type] then
        local from = seek[item.type]
        if nested[#nested] == nil or nested[#nested] == from.type then
          local target_result = result
          if markers[item.type].type == 'latex' then
            target_result = latex_result
          end

          table.insert(target_result, {
            type = item.type,
            from = from.range,
            to = item.range,
          })

          seek[item.type] = nil
          nested[#nested] = nil
          can_nest = true

          for t, pos in pairs(seek) do
            if
              pos.range.start.line == from.range.start.line
              and pos.range.start.character > from.range['end'].character
              and pos.range.start.character < item.range.start.character
            then
              seek[t] = nil
            end
          end
        end
      elseif can_nest then
        -- escaped strings have no pairs, their markup info is self-contained
        if item.type == '\\s' then
          table.insert(result, {
            type = item.type,
            from = item.range,
            to = item.range,
          })
        else
          seek[item.type] = item
          nested[#nested + 1] = item.type
          can_nest = markers[item.type].nestable
        end
      end
    end

    if item.type == '[' then
      seek_link = item
    end

    if item.type == ']' and seek_link then
      table.insert(link_result, {
        from = seek_link.range,
        to = item.range,
      })
      seek_link = nil
    end
  end

  return {
    ranges = result,
    link_ranges = link_result,
    latex_ranges = latex_result,
  }
end, {
  key = function(bufnr, line_index)
    return bufnr .. '__' .. line_index
  end,
})

local function apply(namespace, bufnr, line_index)
  bufnr = bufnr or 0
  local root = get_tree(bufnr)
  if not root then
    return
  end

  local result = get_matches(bufnr, line_index, root)
  local hide_markers = config.org_hide_emphasis_markers

  for _, range in ipairs(result.ranges) do
    local hl_offset = 0
    if markers[range.type].delimiter_hl then
      hl_offset = 1
      -- Leading delimiter
      vim.api.nvim_buf_set_extmark(bufnr, namespace, range.from.start.line, range.from.start.character, {
        ephemeral = true,
        end_col = range.from.start.character + hl_offset,
        hl_group = markers[range.type].hl_name .. '_delimiter',
        spell = markers[range.type].spell,
        priority = 110 + range.from.start.character,
      })

      -- Closing delimiter
      vim.api.nvim_buf_set_extmark(bufnr, namespace, range.from.start.line, range.to['end'].character - hl_offset, {
        ephemeral = true,
        end_col = range.to['end'].character,
        hl_group = markers[range.type].hl_name .. '_delimiter',
        spell = markers[range.type].spell,
        priority = 110 + range.from.start.character,
      })
    end

    -- Main body highlight
    vim.api.nvim_buf_set_extmark(bufnr, namespace, range.from.start.line, range.from.start.character + hl_offset, {
      ephemeral = true,
      end_col = range.to['end'].character - hl_offset,
      hl_group = markers[range.type].hl_name,
      spell = markers[range.type].spell,
      priority = 110 + range.from.start.character,
    })

    if hide_markers then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, range.from.start.line, range.from.start.character, {
        end_col = range.from['end'].character,
        ephemeral = true,
        conceal = '',
      })
      vim.api.nvim_buf_set_extmark(bufnr, namespace, range.to.start.line, range.to.start.character, {
        end_col = range.to['end'].character,
        ephemeral = true,
        conceal = '',
      })
    end
  end

  for _, link_range in ipairs(result.link_ranges) do
    local line = vim.api.nvim_buf_get_lines(bufnr, link_range.from.start.line, link_range.from.start.line + 1, false)[1]
    local link = line:sub(link_range.from.start.character + 1, link_range.to['end'].character)
    local alias = link:find('%]%[') or 1
    local link_end = link:find('%]%[') or (link:len() - 1)

    vim.api.nvim_buf_set_extmark(bufnr, namespace, link_range.from.start.line, link_range.from.start.character, {
      ephemeral = true,
      end_col = link_range.to['end'].character,
      hl_group = 'org_hyperlink',
      priority = 110,
    })

    vim.api.nvim_buf_set_extmark(bufnr, namespace, link_range.from.start.line, link_range.from.start.character, {
      ephemeral = true,
      end_col = link_range.from.start.character + 1 + alias,
      conceal = '',
    })

    vim.api.nvim_buf_set_extmark(bufnr, namespace, link_range.from.start.line, link_range.from.start.character + 2, {
      ephemeral = true,
      end_col = link_range.from.start.character - 1 + link_end,
      spell = false,
    })

    vim.api.nvim_buf_set_extmark(bufnr, namespace, link_range.from.start.line, link_range.to['end'].character - 2, {
      ephemeral = true,
      end_col = link_range.to['end'].character,
      conceal = '',
    })
  end

  for _, latex_range in ipairs(result.latex_ranges) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, latex_range.from.start.line, latex_range.from.start.character, {
      ephemeral = true,
      end_col = latex_range.to['end'].character,
      hl_group = markers[latex_range.type].hl_name,
      spell = markers[latex_range.type].spell,
      priority = 110 + latex_range.from.start.character,
    })
  end
end

local function setup()
  for _, marker in pairs(markers) do
    vim.cmd(string.format(marker.hl_cmd, marker.hl_name))
    if marker.delimiter_hl then
      vim.cmd(string.format(marker.hl_cmd, marker.hl_name .. '_delimiter'))
    end
  end
  vim.cmd('hi def link org_hyperlink Underlined')
  load_deps()
end

return {
  apply = apply,
  setup = setup,
}
