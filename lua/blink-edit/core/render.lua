--- Render module for blink-edit
--- Displays predictions using virtual text (ghost text style)
--- Applies predictions by replacing the entire window

local M = {}

local state = require("blink-edit.core.state")
local diff = require("blink-edit.core.diff")
local config = require("blink-edit.config")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")

-- Namespace for extmarks
local ns = vim.api.nvim_create_namespace("blink-edit")

---@type table<number, number[]> Buffer -> list of extmark IDs
local extmarks = {}

---@type table<number, { win_id: number, buf_id: number }[]> Buffer -> overlay windows
local overlay_windows = {}

local JUMP_TEXT = " ⇥ TAB "

-- =============================================================================
-- Overlay Window Helpers (adapted from cursortab.nvim)
-- =============================================================================

--- Get the editor column offset (signs, number col, etc.)
---@param win number
---@return number
local function get_editor_col_offset(win)
  local wininfo = vim.fn.getwininfo(win)
  if #wininfo > 0 then
    return wininfo[1].textoff or 0
  end
  return 0
end

--- Trim a string by a given number of display columns from the left
---@param text string
---@param display_cols number
---@return string trimmed_text
local function trim_left_display_cols(text, display_cols)
  if not text or text == "" or display_cols <= 0 then
    return text
  end

  local total_chars = vim.fn.strchars(text)
  local trimmed_chars = 0
  local accumulated_width = 0

  while trimmed_chars < total_chars and accumulated_width < display_cols do
    local ch = vim.fn.strcharpart(text, trimmed_chars, 1)
    local ch_width = vim.fn.strdisplaywidth(ch)
    accumulated_width = accumulated_width + ch_width
    trimmed_chars = trimmed_chars + 1
  end

  return vim.fn.strcharpart(text, trimmed_chars)
end

--- Create transparent overlay window for completion content
---@param parent_win number
---@param buffer_line number 0-indexed buffer line
---@param col number 0-indexed column
---@param content string|string[]
---@param syntax_ft string|nil
---@param winhl string|nil
---@param min_width number|nil
---@return number overlay_win, number overlay_buf
local function create_overlay_window(parent_win, buffer_line, col, content, syntax_ft, winhl, min_width)
  local overlay_buf = vim.api.nvim_create_buf(false, true)
  local content_lines = type(content) == "table" and content or { content }

  local leftcol = vim.api.nvim_win_call(parent_win, function()
    local view = vim.fn.winsaveview()
    return view.leftcol or 0
  end)

  local trim_cols = math.max(0, leftcol - col)
  if trim_cols > 0 then
    for i, line_content in ipairs(content_lines) do
      content_lines[i] = trim_left_display_cols(line_content or "", trim_cols)
    end
  end

  vim.api.nvim_buf_set_lines(overlay_buf, 0, -1, false, content_lines)
  if syntax_ft and syntax_ft ~= "" then
    vim.api.nvim_set_option_value("filetype", syntax_ft, { buf = overlay_buf })
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = overlay_buf })

  local max_width = 0
  for _, line_content in ipairs(content_lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line_content))
  end
  if min_width and min_width > max_width then
    local adjusted_min_width = math.max(0, min_width - trim_cols)
    max_width = math.max(max_width, adjusted_min_width)
  end

  local left_offset = get_editor_col_offset(parent_win)
  local first_visible_line = vim.api.nvim_win_call(parent_win, function()
    return vim.fn.line("w0")
  end)
  local window_relative_line = buffer_line - (first_visible_line - 1)

  local overlay_win = vim.api.nvim_open_win(overlay_buf, false, {
    relative = "win",
    win = parent_win,
    row = window_relative_line,
    col = left_offset + math.max(0, col - leftcol),
    width = math.max(1, max_width),
    height = #content_lines,
    style = "minimal",
    zindex = 1,
    focusable = false,
    fixed = true,
  })

  vim.api.nvim_set_option_value("winblend", 0, { win = overlay_win })
  if winhl and winhl ~= "" then
    vim.api.nvim_set_option_value("winhighlight", "Normal:" .. winhl, { win = overlay_win })
  end

  return overlay_win, overlay_buf
end

--- Create a hover preview window near the cursor
---@param parent_win number
---@param content string|string[]
---@param syntax_ft string|nil
---@return number preview_win, number preview_buf
local function create_hover_window(parent_win, content, syntax_ft)
  local preview_buf = vim.api.nvim_create_buf(false, true)
  local content_lines = type(content) == "table" and content or { content }

  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, content_lines)
  if syntax_ft and syntax_ft ~= "" then
    vim.api.nvim_set_option_value("filetype", syntax_ft, { buf = preview_buf })
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buf })

  local max_width = 0
  for _, line_content in ipairs(content_lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line_content))
  end

  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.max(1, max_width),
    height = #content_lines,
    style = "minimal",
    border = "rounded",
    zindex = 50,
    focusable = false,
  })

  vim.api.nvim_set_option_value("winblend", 0, { win = preview_win })
  vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = preview_win })

  return preview_win, preview_buf
end

--- Track overlay window for cleanup
---@param bufnr number
---@param win_id number
---@param buf_id number
local function track_overlay_window(bufnr, win_id, buf_id)
  overlay_windows[bufnr] = overlay_windows[bufnr] or {}
  table.insert(overlay_windows[bufnr], { win_id = win_id, buf_id = buf_id })
end

--- Close and cleanup overlay windows for a buffer
---@param bufnr number
local function clear_overlay_windows(bufnr)
  local windows = overlay_windows[bufnr]
  if not windows then
    return
  end

  for _, info in ipairs(windows) do
    if info.win_id and vim.api.nvim_win_is_valid(info.win_id) then
      pcall(vim.api.nvim_win_close, info.win_id, true)
    end
    if info.buf_id and vim.api.nvim_buf_is_valid(info.buf_id) then
      pcall(vim.api.nvim_buf_delete, info.buf_id, { force = true })
    end
  end

  overlay_windows[bufnr] = nil
end

-- =============================================================================
-- Display Functions (one per hunk type)
-- =============================================================================

--- Show an insertion hunk as virtual lines with overlay window
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param current_win number
---@param extmark_list number[] List to append extmark IDs to
local function show_insertion(bufnr, hunk, window_start, current_win, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return
  end

  -- Anchor line: after line start_old in the window
  -- For insertion at start_old=0, anchor at line 0 (first line)
  local anchor_line = window_start + hunk.start_old - 1 -- 1-indexed buffer line
  local anchor_line_0 = anchor_line - 1 -- 0-indexed for API

  -- Clamp to buffer bounds
  if anchor_line_0 < 0 then
    anchor_line_0 = 0
  end
  if anchor_line_0 >= line_count then
    anchor_line_0 = line_count - 1
  end

  -- Build empty virt_lines (overlay renders actual content)
  local virt_lines = {}
  for _ = 1, #hunk.new_lines do
    table.insert(virt_lines, { { "", "Normal" } })
  end

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line_0, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false, -- Show below anchor line
  })
  table.insert(extmark_list, mark_id)

  local syntax_ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  local overlay_line_0 = anchor_line_0 + 1
  local overlay_win, overlay_buf = create_overlay_window(current_win, overlay_line_0, 0, hunk.new_lines, syntax_ft, nil, nil)
  track_overlay_window(bufnr, overlay_win, overlay_buf)

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(string.format("Insertion: %d lines after buffer line %d", #hunk.new_lines, anchor_line))
  end
end

--- Show a deletion hunk with [delete] markers at end of each line
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param extmark_list number[] List to append extmark IDs to
local function show_deletion(bufnr, hunk, window_start, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for i = 1, hunk.count_old do
    local lnum = window_start + hunk.start_old + i - 2 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
        virt_text = { { " [delete]", "BlinkEditDeletion" } },
        virt_text_pos = "eol",
      })
      table.insert(extmark_list, mark_id)
    end
  end

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(
      string.format("Deletion: %d lines starting at buffer line %d", hunk.count_old, window_start + hunk.start_old - 1)
    )
  end
end

--- Show a modification hunk with inline ghost text for each changed line
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param extmark_list number[] List to append extmark IDs to
local function show_modification(bufnr, hunk, window_start, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if not hunk.line_changes then
    return
  end

  for _, lc in ipairs(hunk.line_changes) do
    local lnum = window_start + hunk.start_old + lc.index - 2 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      local change = lc.change

      -- Get current line length to ensure col is valid
      local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, lnum, lnum + 1, false)
      local current_line = (ok and line_data[1]) or ""
      local col = math.min(change.col, #current_line)

      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, col, {
        virt_text = { { change.text, "BlinkEditPreview" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
      table.insert(extmark_list, mark_id)

      if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
        log.debug2(string.format("Modification: %s at line %d col %d: %q", change.type, lnum + 1, col, change.text))
      end
    end
  end
end

--- Check if completion menu (pum) is visible
---@return boolean
local function is_completion_menu_visible()
  return vim.fn.pumvisible() == 1
end

--- Render a single-line insertion inline at the cursor (Copilot-style suffix only)
---@param bufnr number
---@param hunk DiffHunk
---@param cursor table|nil
---@param window_start number 1-indexed
---@param current_win number
---@param extmark_list number[]
---@return boolean success
local function show_inline_insertion(bufnr, hunk, cursor, window_start, current_win, extmark_list)
  if not cursor or hunk.count_new ~= 1 then
    return false
  end

  local line_0 = cursor[1] - 1
  if line_0 < 0 then
    return false
  end

  -- Check if this insertion is at or right after the cursor line
  local cursor_offset = cursor[1] - window_start + 1
  local at_or_after_cursor_line = (hunk.start_old == cursor_offset or hunk.start_old == cursor_offset + 1)

  if not at_or_after_cursor_line or is_completion_menu_visible() then
    return false
  end

  local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, line_0, line_0 + 1, false)
  local current_line = (ok and line_data[1]) or ""
  local cursor_col = math.min(cursor[2] or #current_line, #current_line)

  local predicted_line = hunk.new_lines[1] or ""
  if predicted_line == "" then
    return false
  end

  -- Copilot-like: only show what continues from the cursor position
  local prefix = current_line:sub(1, cursor_col)
  if predicted_line:sub(1, #prefix) ~= prefix then
    -- Not a same-line continuation; don't fake it
    return false
  end

  local suffix = predicted_line:sub(#prefix + 1)
  if suffix == "" then
    return false
  end

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, line_0, cursor_col, {
    virt_text = { { suffix, "BlinkEditPreview" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
  table.insert(extmark_list, mark_id)

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(string.format("Inline insertion: suffix %q at line %d col %d", suffix, line_0 + 1, cursor_col))
  end

  return true
end

--- Build unified diff lines for a replacement hunk
---@param hunk DiffHunk
---@return string[]
local function replacement_diff_lines(hunk)
  local old_text = table.concat(hunk.old_lines or {}, "\n")
  local new_text = table.concat(hunk.new_lines or {}, "\n")
  local unified = vim.diff(old_text, new_text, { result_type = "unified", ctxlen = 2 })
  if unified and unified ~= "" then
    return vim.split(unified, "\n", { plain = true })
  end
  return hunk.new_lines or {}
end

--- Show a replacement hunk with [replace] markers and overlay window for new content
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param current_win number
---@param extmark_list number[] List to append extmark IDs to
local function show_replacement(bufnr, hunk, window_start, current_win, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Mark old lines with [replace]
  for i = 1, hunk.count_old do
    local lnum = window_start + hunk.start_old + i - 2 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
        virt_text = { { " [replace]", "BlinkEditDeletion" } },
        virt_text_pos = "eol",
      })
      table.insert(extmark_list, mark_id)
    end
  end

  -- Show new content as overlay below last old line
  if hunk.count_new > 0 then
    local anchor_line_0 = window_start + hunk.start_old + hunk.count_old - 2 -- 0-indexed
    if anchor_line_0 < 0 then
      anchor_line_0 = 0
    end
    if anchor_line_0 >= line_count then
      anchor_line_0 = line_count - 1
    end

    local virt_lines = {}
    for _ = 1, #hunk.new_lines do
      table.insert(virt_lines, { { "", "Normal" } })
    end

    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line_0, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
    table.insert(extmark_list, mark_id)

    local syntax_ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
    local overlay_line_0 = anchor_line_0 + 1
    local overlay_win, overlay_buf = create_overlay_window(current_win, overlay_line_0, 0, hunk.new_lines, syntax_ft, nil, nil)
    track_overlay_window(bufnr, overlay_win, overlay_buf)
  end

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(
      string.format(
        "Replacement: %d old lines -> %d new lines at buffer line %d",
        hunk.count_old,
        hunk.count_new,
        window_start + hunk.start_old - 1
      )
    )
  end
end

--- Get a stable anchor line for jump indicators
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number
---@return number|nil line_0
local function get_jump_anchor_line(bufnr, hunk, window_start)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return nil
  end

  local anchor_line = window_start + hunk.start_old - 1
  local anchor_line_0 = anchor_line - 1

  if anchor_line_0 < 0 then
    anchor_line_0 = 0
  end
  if anchor_line_0 >= line_count then
    anchor_line_0 = line_count - 1
  end

  return anchor_line_0
end

--- Show a jump indicator inline at the end of a line
---@param bufnr number
---@param line_0 number 0-indexed line number
---@param extmark_list number[]
local function show_jump_indicator_inline(bufnr, line_0, extmark_list)
  local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, line_0, line_0 + 1, false)
  local line_content = (ok and line_data[1]) or ""
  local col = #line_content

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, line_0, col, {
    virt_text = { { JUMP_TEXT, "BlinkEditJump" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
  table.insert(extmark_list, mark_id)
end

--- Show a jump indicator for the next hunk (rendered as a virtual line below the target)
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number
---@param extmark_list number[]
local function show_jump_indicator(bufnr, hunk, window_start, extmark_list)
  local anchor_line_0 = get_jump_anchor_line(bufnr, hunk, window_start)
  if anchor_line_0 == nil then
    return
  end

  -- Render as a virtual line below the target hunk
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line_0, 0, {
    virt_lines = { { { JUMP_TEXT, "BlinkEditJump" } } },
    virt_lines_above = false, -- Show below the anchor line
  })
  table.insert(extmark_list, mark_id)
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Clear all extmarks for a buffer
---@param bufnr number
function M.clear(bufnr)
  -- Clear all extmarks in our namespace
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  extmarks[bufnr] = nil
  clear_overlay_windows(bufnr)

  -- Clear prediction state
  state.clear_prediction(bufnr)
end

--- Check if there's a visible prediction
---@param bufnr number
---@return boolean
function M.has_visible(bufnr)
  local marks = extmarks[bufnr]
  return marks ~= nil and #marks > 0
end

--- Show prediction as ghost text
--- Uses vim.diff() to properly identify insertions, deletions, and modifications
--- Only shows changes at or below cursor position (next-edit semantics)
---@param bufnr number
---@param prediction BlinkEditPrediction
function M.show(bufnr, prediction)
  -- Clear existing extmarks first
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  extmarks[bufnr] = {}
  clear_overlay_windows(bufnr)

  if not prediction then
    return
  end

  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines
  local window_start = prediction.window_start
  local cursor = prediction.cursor

  if not snapshot or not predicted then
    return
  end

  -- Calculate cursor offset in window (1-indexed)
  local cursor_offset = 1
  if cursor then
    cursor_offset = cursor[1] - window_start + 1
    cursor_offset = math.max(1, cursor_offset) -- Clamp to valid range
  end

  -- Compute diff using the new diff module
  local diff_result = diff.compute(snapshot, predicted)

  if not diff_result.has_changes then
    if vim.g.blink_edit_debug then
      log.debug("No changes between snapshot and predicted")
    end
    return
  end

  -- Process each hunk, but only if at or below cursor (next-edit semantics)
  local shown_count = 0
  local skipped_count = 0
  local first_hunk = nil
  local cfg = config.get()
  local hover_shown = false
  local inline_at_cursor = false -- Track if we're showing inline at cursor

  local current_win = vim.api.nvim_get_current_win()

  for _, hunk in ipairs(diff_result.hunks) do
    -- Only show hunks at or below cursor position
    if hunk.start_old >= cursor_offset then
      shown_count = shown_count + 1
      if not first_hunk then
        first_hunk = hunk
      end
      if hunk.type == "insertion" then
        local handled = false
        if cfg.mode == "completion" then
          -- Check if completion menu is visible - if so, use hover window
          local pum_visible = is_completion_menu_visible()
          local at_or_after_cursor = (hunk.start_old == cursor_offset or hunk.start_old == cursor_offset + 1)

          if hunk.count_new == 1 and cursor and at_or_after_cursor and not pum_visible then
            -- Try inline ghost text (Copilot-style suffix)
            handled = show_inline_insertion(bufnr, hunk, cursor, window_start, current_win, extmarks[bufnr])
            if handled then
              inline_at_cursor = true
            end
          end

          -- Use hover window for: multi-line, not at cursor, or when completion is visible
          if not handled and not hover_shown then
            local syntax_ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
            local ok, preview_win, preview_buf = pcall(create_hover_window, current_win, hunk.new_lines, syntax_ft)
            if ok and preview_win then
              track_overlay_window(bufnr, preview_win, preview_buf)
              hover_shown = true
              handled = true
              if vim.g.blink_edit_debug then
                log.debug("Hover window created for insertion")
              end
            elseif vim.g.blink_edit_debug then
              log.debug("Failed to create hover window: " .. tostring(preview_win))
            end
          end
        end
        if not handled then
          show_insertion(bufnr, hunk, window_start, current_win, extmarks[bufnr])
        end
      elseif hunk.type == "deletion" then
        show_deletion(bufnr, hunk, window_start, extmarks[bufnr])
      elseif hunk.type == "modification" then
        show_modification(bufnr, hunk, window_start, extmarks[bufnr])
      elseif hunk.type == "replacement" then
        local handled = false
        -- Always use hover window for replacements with unified diff
        if not hover_shown then
          local diff_lines = replacement_diff_lines(hunk)
          local ok, preview_win, preview_buf = pcall(create_hover_window, current_win, diff_lines, "diff")
          if ok and preview_win then
            track_overlay_window(bufnr, preview_win, preview_buf)
            hover_shown = true
            handled = true
          end
        end
        if not handled then
          show_replacement(bufnr, hunk, window_start, current_win, extmarks[bufnr])
        end
      end
    else
      skipped_count = skipped_count + 1
      if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
        log.debug2(
          string.format(
            "Skipping hunk above cursor: %s at line %d (cursor at %d)",
            hunk.type,
            hunk.start_old,
            cursor_offset
          )
        )
      end
    end
  end

  if not first_hunk and prediction.allow_fallback and diff_result.has_changes and #diff_result.hunks > 0 then
    local fallback = diff_result.hunks[1]
    if vim.g.blink_edit_debug then
      log.debug("Render fallback: showing first hunk above cursor")
    end
    if fallback.type == "insertion" then
      local handled = false
      if cfg.mode == "completion" then
        -- Check if completion menu is visible - if so, use hover window
        local pum_visible = is_completion_menu_visible()
        local at_or_after_cursor = (fallback.start_old == cursor_offset or fallback.start_old == cursor_offset + 1)

        if fallback.count_new == 1 and cursor and at_or_after_cursor and not pum_visible then
          -- Try inline ghost text (Copilot-style suffix)
          handled = show_inline_insertion(bufnr, fallback, cursor, window_start, current_win, extmarks[bufnr])
          if handled then
            inline_at_cursor = true
          end
        end

        -- Use hover window for: multi-line, not at cursor, or when completion is visible
        if not handled and not hover_shown then
          local syntax_ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
          local ok, preview_win, preview_buf = pcall(create_hover_window, current_win, fallback.new_lines, syntax_ft)
          if ok and preview_win then
            track_overlay_window(bufnr, preview_win, preview_buf)
            hover_shown = true
            handled = true
          end
        end
      end
      if not handled then
        show_insertion(bufnr, fallback, window_start, current_win, extmarks[bufnr])
      end
    elseif fallback.type == "deletion" then
      show_deletion(bufnr, fallback, window_start, extmarks[bufnr])
    elseif fallback.type == "modification" then
      show_modification(bufnr, fallback, window_start, extmarks[bufnr])
    elseif fallback.type == "replacement" then
      local handled = false
      -- Always use hover window for replacements with unified diff
      if not hover_shown then
        local diff_lines = replacement_diff_lines(fallback)
        local ok, preview_win, preview_buf = pcall(create_hover_window, current_win, diff_lines, "diff")
        if ok and preview_win then
          track_overlay_window(bufnr, preview_win, preview_buf)
          hover_shown = true
          handled = true
        end
      end
      if not handled then
        show_replacement(bufnr, fallback, window_start, current_win, extmarks[bufnr])
      end
    end
    first_hunk = fallback
  end

  if first_hunk and not inline_at_cursor then
    -- Only show TAB indicator when not showing inline at cursor
    -- (ghost text is already visible on the same line)
    show_jump_indicator(bufnr, first_hunk, window_start, extmarks[bufnr])
  end

  if vim.g.blink_edit_debug then
    local summary = diff.summarize(diff_result)
    log.debug(
      string.format(
        "Showing ghost text: %d hunks shown, %d skipped (ins=%d, del=%d, mod=%d, repl=%d)",
        shown_count,
        skipped_count,
        summary.insertions,
        summary.deletions,
        summary.modifications,
        summary.replacements
      )
    )
  end
end

local function build_merged_result(prediction)
  local window_start = prediction.window_start
  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines
  local cursor = prediction.cursor

  if not snapshot or not predicted then
    return nil, nil, nil
  end

  local cursor_offset = 1
  if cursor then
    cursor_offset = cursor[1] - window_start + 1
    cursor_offset = math.max(1, cursor_offset)
  end

  local diff_result = diff.compute(snapshot, predicted)
  local line_offset = 0

  for _, hunk in ipairs(diff_result.hunks) do
    if hunk.start_old < cursor_offset then
      line_offset = line_offset + (hunk.count_new - hunk.count_old)
    end
  end

  local merged = {}

  for i = 1, cursor_offset - 1 do
    table.insert(merged, snapshot[i])
  end

  local pred_start = cursor_offset + line_offset
  if pred_start < 1 then
    pred_start = 1
  end

  for i = pred_start, #predicted do
    table.insert(merged, predicted[i])
  end

  return merged, cursor_offset, line_offset
end

--- Apply a prediction to the buffer (uses supplied prediction)
---@param bufnr number
---@param prediction BlinkEditPrediction
---@return boolean success, string[]|nil merged_lines
local function apply_prediction(bufnr, prediction)
  if not prediction then
    return false, nil
  end

  local window_start = prediction.window_start
  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines

  if not snapshot or not predicted then
    return false, nil
  end

  -- Race condition check: verify buffer content still matches snapshot
  local ok, current = pcall(vim.api.nvim_buf_get_lines, bufnr, window_start - 1, window_start - 1 + #snapshot, false)

  if not ok then
    if vim.g.blink_edit_debug then
      log.debug("Failed to read buffer for prediction apply", vim.log.levels.WARN)
    end
    M.clear(bufnr)
    return false, nil
  end

  if not utils.lines_equal(current, snapshot) then
    -- Buffer changed since prediction was made, discard
    if vim.g.blink_edit_debug then
      log.debug("Buffer changed since prediction, discarding stale prediction")
    end
    M.clear(bufnr)
    return false, nil
  end
  local merged, cursor_offset, line_offset = build_merged_result(prediction)
  if not merged then
    return false, nil
  end

  -- Apply merged result
  vim.api.nvim_buf_set_lines(
    bufnr,
    window_start - 1, -- 0-indexed start
    window_start - 1 + #snapshot, -- end (exclusive)
    false,
    merged
  )

  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "Applied prediction: cursor_offset=%d, line_offset=%d, merged=%d lines",
        cursor_offset,
        line_offset,
        #merged
      )
    )
  end

  -- Clear the visual indicators (but don't clear prediction state yet - engine needs it)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  extmarks[bufnr] = nil
  clear_overlay_windows(bufnr)

  return true, merged
end

--- Apply the current prediction to the buffer
--- Only applies changes at or below cursor position (next-edit semantics)
--- Keeps snapshot content above cursor, uses predicted content at/below cursor
---@param bufnr number
---@return boolean success, string[]|nil merged_lines
function M.apply(bufnr)
  local prediction = state.get_prediction(bufnr)
  return apply_prediction(bufnr, prediction)
end

--- Apply a supplied prediction (used for partial hunks)
---@param bufnr number
---@param prediction BlinkEditPrediction
---@return boolean success, string[]|nil merged_lines
function M.apply_with_prediction(bufnr, prediction)
  return apply_prediction(bufnr, prediction)
end

--- Get namespace ID (for testing/debugging)
---@return number
function M.get_namespace()
  return ns
end

--- Get extmark IDs for a buffer (for testing/debugging)
---@param bufnr number
---@return number[]
function M.get_extmarks(bufnr)
  return extmarks[bufnr] or {}
end

return M
