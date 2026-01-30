--- User action tracking for blink-edit
--- Tracks cursor movements, insertions, and deletions for Sweep API context

local M = {}

local utils = require("blink-edit.utils")

---@class UserAction
---@field action_type string "cursor_movement" | "insert_char" | "delete_char" | "insert_selection" | "delete_selection"
---@field line_number number 1-indexed line number
---@field offset number Byte offset within the line
---@field file_path string Normalized file path
---@field timestamp number Epoch milliseconds

-- Maximum number of actions to track per buffer
local MAX_ACTIONS = 50

---@type table<number, UserAction[]>
local buffer_actions = {}

---@type table<number, { line: number, col: number, text: string }|nil>
local buffer_prev_state = {}

-- =============================================================================
-- Internal Helpers
-- =============================================================================

--- Get current timestamp in milliseconds
---@return number
local function get_timestamp()
  return vim.uv.now()
end

--- Trim actions to max size (keep most recent)
---@param actions UserAction[]
---@return UserAction[]
local function trim_actions(actions)
  if #actions <= MAX_ACTIONS then
    return actions
  end

  local result = {}
  local start_idx = #actions - MAX_ACTIONS + 1
  for i = start_idx, #actions do
    table.insert(result, actions[i])
  end
  return result
end

--- Get or create actions array for buffer
---@param bufnr number
---@return UserAction[]
local function get_or_create(bufnr)
  if not buffer_actions[bufnr] then
    buffer_actions[bufnr] = {}
  end
  return buffer_actions[bufnr]
end

-- =============================================================================
-- Recording Functions
-- =============================================================================

--- Record a cursor movement
---@param bufnr number
---@param line number 1-indexed line
---@param col number 0-indexed column
function M.record_cursor_move(bufnr, line, col)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
  local actions = get_or_create(bufnr)

  -- Avoid duplicate consecutive cursor movements to the same position
  if #actions > 0 then
    local last = actions[#actions]
    if last.action_type == "cursor_movement" and last.line_number == line and last.offset == col then
      return
    end
  end

  table.insert(actions, {
    action_type = "cursor_movement",
    line_number = line,
    offset = col,
    file_path = filepath,
    timestamp = get_timestamp(),
  })

  buffer_actions[bufnr] = trim_actions(actions)
end

--- Record a text insertion
---@param bufnr number
---@param line number 1-indexed line
---@param col number 0-indexed column
---@param text string Inserted text
function M.record_insert(bufnr, line, col, text)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
  local actions = get_or_create(bufnr)

  -- Determine action type based on text length
  local action_type = #text > 1 and "insert_selection" or "insert_char"

  table.insert(actions, {
    action_type = action_type,
    line_number = line,
    offset = col,
    file_path = filepath,
    timestamp = get_timestamp(),
  })

  buffer_actions[bufnr] = trim_actions(actions)
end

--- Record a text deletion
---@param bufnr number
---@param line number 1-indexed line
---@param col number 0-indexed column
---@param count number Number of characters deleted
function M.record_delete(bufnr, line, col, count)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
  local actions = get_or_create(bufnr)

  -- Determine action type based on deletion size
  local action_type = count > 1 and "delete_selection" or "delete_char"

  table.insert(actions, {
    action_type = action_type,
    line_number = line,
    offset = col,
    file_path = filepath,
    timestamp = get_timestamp(),
  })

  buffer_actions[bufnr] = trim_actions(actions)
end

-- =============================================================================
-- State Tracking for Change Detection
-- =============================================================================

--- Capture current buffer state (call before text change events)
---@param bufnr number
function M.capture_state(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok_cursor then
    cursor = { 1, 0 }
  end

  local line_num = cursor[1]
  local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, line_num - 1, line_num, false)
  local line_text = (ok_lines and lines[1]) or ""

  buffer_prev_state[bufnr] = {
    line = line_num,
    col = cursor[2],
    text = line_text,
  }
end

--- Detect and record changes by comparing with previous state
---@param bufnr number
function M.detect_changes(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local prev = buffer_prev_state[bufnr]
  if not prev then
    return
  end

  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok_cursor then
    return
  end

  local line_num = cursor[1]
  local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, line_num - 1, line_num, false)
  local current_text = (ok_lines and lines[1]) or ""

  -- Same line comparison
  if prev.line == line_num then
    local len_diff = #current_text - #prev.text

    if len_diff > 0 then
      -- Text was inserted
      M.record_insert(bufnr, line_num, cursor[2], string.rep("x", len_diff))
    elseif len_diff < 0 then
      -- Text was deleted
      M.record_delete(bufnr, line_num, cursor[2], -len_diff)
    end
  else
    -- Line changed - treat as cursor movement
    M.record_cursor_move(bufnr, line_num, cursor[2])
  end

  -- Update state for next comparison
  buffer_prev_state[bufnr] = {
    line = line_num,
    col = cursor[2],
    text = current_text,
  }
end

-- =============================================================================
-- Public Query Functions
-- =============================================================================

--- Get recent actions for a buffer
---@param bufnr number
---@param limit number|nil Maximum number of actions to return (default: all)
---@return UserAction[]
function M.get_recent_actions(bufnr, limit)
  local actions = buffer_actions[bufnr] or {}

  if not limit or limit >= #actions then
    return actions
  end

  local result = {}
  local start_idx = #actions - limit + 1
  for i = start_idx, #actions do
    table.insert(result, actions[i])
  end
  return result
end

--- Clear actions for a buffer
---@param bufnr number
function M.clear(bufnr)
  buffer_actions[bufnr] = nil
  buffer_prev_state[bufnr] = nil
end

--- Clear all tracked actions
function M.clear_all()
  buffer_actions = {}
  buffer_prev_state = {}
end

--- Get action count for a buffer (for debugging)
---@param bufnr number
---@return number
function M.get_action_count(bufnr)
  local actions = buffer_actions[bufnr]
  return actions and #actions or 0
end

return M
