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
end

return M
