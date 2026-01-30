--- Logging utilities for blink-edit
--- Centralizes debug/info/warn/error notifications with debounce

local M = {}

local uv = vim.uv or vim.loop

-- Debounce state for error notifications
local last_error_time = 0
local ERROR_DEBOUNCE_MS = 5000

-- Log storage for viewing history
local log_entries = {}

local LEVEL_NAMES = {
  [vim.log.levels.DEBUG] = "DEBUG",
  [vim.log.levels.INFO] = "INFO",
  [vim.log.levels.WARN] = "WARN",
  [vim.log.levels.ERROR] = "ERROR",
}

local LEVEL_VALUES = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
  off = vim.log.levels.ERROR + 1,
}

--- Get configured log level
---@return number
local function get_configured_level()
  local ok, config = pcall(require, "blink-edit.config")
  if not ok then
    return vim.log.levels.INFO
  end
  local cfg = config.get()
  local level_name = cfg.logging and cfg.logging.level or "info"
  return LEVEL_VALUES[level_name] or vim.log.levels.INFO
end

--- Get configured max entries
---@return number
local function get_max_entries()
  local ok, config = pcall(require, "blink-edit.config")
  if not ok then
    return 100
  end
  local cfg = config.get()
  return cfg.logging and cfg.logging.max_entries or 100
end

--- Check if a log level should be displayed
---@param level number
---@return boolean
local function should_log(level)
  return level >= get_configured_level()
end

--- Store a log entry
---@param msg string
---@param level number
local function store_log(msg, level)
  local entry = {
    timestamp = os.date("%H:%M:%S"),
    level = level,
    level_name = LEVEL_NAMES[level] or "UNKNOWN",
    message = msg,
  }
  table.insert(log_entries, entry)

  -- Trim to max size
  local max_entries = get_max_entries()
  while #log_entries > max_entries do
    table.remove(log_entries, 1)
  end
end

local function notify(msg, level)
  store_log(msg, level)
  if should_log(level) then
    vim.schedule(function()
      vim.notify("[blink-edit] " .. msg, level)
    end)
  end
end

---@param msg string
---@param level? number
function M.debug(msg, level)
  local log_level = level or vim.log.levels.DEBUG
  -- Always store debug logs (for viewing later with :BlinkEditShowLogs)
  store_log(msg, log_level)

  -- Show if vim.g.blink_edit_debug is set OR if configured level allows it
  if vim.g.blink_edit_debug or should_log(log_level) then
    vim.schedule(function()
      vim.notify("[blink-edit] " .. msg, log_level)
      if vim.g.blink_edit_debug then
        pcall(vim.api.nvim_echo, { { "[blink-edit] " .. msg } }, true, {})
      end
    end)
  end
end

---@param msg string
---@param level? number
function M.debug2(msg, level)
  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    M.debug(msg, level)
  end
end

---@param msg string
function M.info(msg)
  notify(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
  notify(msg, vim.log.levels.WARN)
end

---@param msg string
---@param debounce? boolean
function M.error(msg, debounce)
  if debounce == nil then
    debounce = true
  end

  local now = uv.now()
  if debounce and (now - last_error_time) < ERROR_DEBOUNCE_MS then
    return
  end
  last_error_time = now

  notify(msg, vim.log.levels.ERROR)
end

--- Get all log entries
---@return table[]
function M.get_entries()
  return log_entries
end

--- Clear all log entries
function M.clear()
  log_entries = {}
end

--- Get log entry count
---@return number
function M.count()
  return #log_entries
end

--- Format log entries for display
---@return string[]
function M.format_entries()
  local lines = {}
  local level_colors = {
    DEBUG = "Comment",
    INFO = "Normal",
    WARN = "WarningMsg",
    ERROR = "ErrorMsg",
  }

  for _, entry in ipairs(log_entries) do
    local line = string.format("[%s] [%s] %s", entry.timestamp, entry.level_name, entry.message)
    table.insert(lines, line)
  end

  return lines
end

--- Show logs in a floating window
function M.show()
  local lines = M.format_entries()
  if #lines == 0 then
    vim.notify("[blink-edit] No log entries", vim.log.levels.INFO)
    return
  end

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "blink-edit-logs"

  -- Set content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Calculate window size
  local width = math.min(120, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 10)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Blink-Edit Logs (" .. #lines .. " entries) ",
    title_pos = "center",
  })

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("blink_edit_logs")
  for i, entry in ipairs(log_entries) do
    local hl = "Normal"
    if entry.level_name == "ERROR" then
      hl = "ErrorMsg"
    elseif entry.level_name == "WARN" then
      hl = "WarningMsg"
    elseif entry.level_name == "DEBUG" then
      hl = "Comment"
    end
    vim.api.nvim_buf_add_highlight(buf, ns, hl, i - 1, 0, -1)
  end

  -- Set up keymaps to close
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })

  -- Scroll to bottom (most recent)
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
end

return M
