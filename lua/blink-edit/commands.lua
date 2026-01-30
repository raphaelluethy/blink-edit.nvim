--- User command registration for blink-edit

local M = {}

local ui = require("blink-edit.ui")
local log = require("blink-edit.log")

---@param handlers { enable: function, disable: function, toggle: function, status: function }
function M.setup(handlers)
  vim.api.nvim_create_user_command("BlinkEditEnable", handlers.enable, {
    desc = "Enable blink-edit",
    force = true,
  })

  vim.api.nvim_create_user_command("BlinkEditDisable", handlers.disable, {
    desc = "Disable blink-edit",
    force = true,
  })

  vim.api.nvim_create_user_command("BlinkEditToggle", handlers.toggle, {
    desc = "Toggle blink-edit",
    force = true,
  })

  vim.api.nvim_create_user_command("BlinkEditStatus", function()
    ui.status()
  end, {
    desc = "Show blink-edit status (includes server health)",
    force = true,
  })

  vim.api.nvim_create_user_command("BlinkEditShowLogs", function()
    log.show()
  end, {
    desc = "Show blink-edit log history",
    force = true,
  })

  vim.api.nvim_create_user_command("BlinkEditClearLogs", function()
    log.clear()
    vim.notify("[blink-edit] Logs cleared", vim.log.levels.INFO)
  end, {
    desc = "Clear blink-edit log history",
    force = true,
  })

  vim.api.nvim_create_user_command("BlinkEditTestSweep", function()
    local sweep = require("blink-edit.backends.sweep_remote")
    local config = require("blink-edit.config")
    local transport = require("blink-edit.transport")
    local cfg = config.get()
    local sweep_cfg = cfg.backends.sweep_remote or {}

    -- Get token
    local token = os.getenv("SWEEP_AI_TOKEN")
    if not token or token == "" then
      vim.notify("[blink-edit] SWEEP_AI_TOKEN not set", vim.log.levels.ERROR)
      return
    end

    vim.notify("[blink-edit] Testing Sweep connection...", vim.log.levels.INFO)
    log.debug("Testing Sweep connection")
    log.debug(string.format("Token length: %d", #token))
    log.debug(string.format("Token prefix: %s...", token:sub(1, 8)))
    log.debug(string.format("URL: %s", sweep_cfg.url or "https://autocomplete.sweep.dev"))

    -- Test with minimal payload
    local test_payload = {
      debug_info = "blink-edit-test",
      repo_name = "test",
      file_path = "test.lua",
      file_contents = "local x = 1",
      cursor_position = 0,
      original_file_contents = "local x = 1",
      recent_changes = "",
      file_chunks = {},
      retrieval_chunks = {},
      recent_user_actions = {},
      multiple_suggestions = false,
      privacy_mode_enabled = false,
      changes_above_cursor = true,
      use_bytes = true,
    }

    local url = (sweep_cfg.url or "https://autocomplete.sweep.dev") .. (sweep_cfg.endpoint or "/backend/next_edit_autocomplete")

    -- Try with brotli compression if available
    local body = vim.json.encode(test_payload)
    local headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. token,
      ["Connection"] = "keep-alive",
    }
    
    -- Check if brotli is available
    if vim.fn.executable("brotli") == 1 then
      local temp_input = vim.fn.tempname() .. ".json"
      local temp_output = temp_input .. ".br"
      local f = io.open(temp_input, "w")
      if f then
        f:write(body)
        f:close()
        local cmd = string.format("brotli -q 1 -o %s %s 2>/dev/null", temp_output, temp_input)
        if os.execute(cmd) == 0 then
          local cf = io.open(temp_output, "rb")
          if cf then
            body = cf:read("*all")
            cf:close()
            headers["Content-Encoding"] = "br"
            log.debug("Test using brotli compression")
          end
        end
        os.remove(temp_input)
        os.remove(temp_output)
      end
    else
      log.debug("Test without compression (brotli not available)")
    end

    transport.request({
      url = url,
      method = "POST",
      headers = headers,
      body = body,
      timeout = 10000,
    }, function(err, response)
      if err then
        vim.notify("[blink-edit] Sweep test failed: " .. err.message, vim.log.levels.ERROR)
        log.debug("Sweep test error: " .. vim.inspect(err))
        return
      end

      vim.notify(string.format("[blink-edit] Sweep test - HTTP %d", response.status), vim.log.levels.INFO)
      log.debug("Sweep test response status: " .. response.status)
      log.debug("Sweep test response headers: " .. vim.inspect(response.headers))
      log.debug("Sweep test response body: " .. vim.inspect(response.body))

      if response.status == 200 then
        vim.notify("[blink-edit] Sweep connection successful!", vim.log.levels.INFO)
      elseif response.status == 403 then
        vim.notify("[blink-edit] Sweep 403 Forbidden - Token may be invalid or expired", vim.log.levels.ERROR)
      elseif response.status == 401 then
        vim.notify("[blink-edit] Sweep 401 Unauthorized - Check token format", vim.log.levels.ERROR)
      else
        vim.notify("[blink-edit] Sweep error: HTTP " .. response.status, vim.log.levels.WARN)
      end
    end)
  end, {
    desc = "Test Sweep AI connection",
    force = true,
  })
end

return M
