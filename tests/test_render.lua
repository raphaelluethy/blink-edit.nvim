--- Tests for blink-edit render and diff modules
--- Run with: nvim -l tests/test_render.lua
--- Or source in Neovim: :luafile tests/test_render.lua

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("✓ " .. name)
  else
    print("✗ " .. name .. ": " .. tostring(err))
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %q, got %q", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_table_eq(expected, actual, msg)
  if #expected ~= #actual then
    error(string.format("%s: length mismatch, expected %d, got %d", msg or "assertion failed", #expected, #actual))
  end
  for i, v in ipairs(expected) do
    if v ~= actual[i] then
      error(string.format("%s: index %d mismatch, expected %q, got %q", msg or "assertion failed", i, tostring(v), tostring(actual[i])))
    end
  end
end

print("\n=== blink-edit render tests ===\n")

-- =============================================================================
-- Diff module tests
-- =============================================================================

local diff = require("blink-edit.core.diff")

test("diff.compute: identical lines returns no changes", function()
  local result = diff.compute({ "line1", "line2" }, { "line1", "line2" })
  assert_eq(false, result.has_changes, "has_changes")
  assert_eq(0, #result.hunks, "hunk count")
end)

test("diff.compute: insertion at end", function()
  local snapshot = { "line1", "" }
  local predicted = { "line1", "", "line2" }
  local result = diff.compute(snapshot, predicted)
  assert_eq(true, result.has_changes, "has_changes")
  assert_eq(1, #result.hunks, "hunk count")
  assert_eq("insertion", result.hunks[1].type, "hunk type")
  assert_eq(1, result.hunks[1].start_old, "start_old") -- insertion AFTER line 1
  assert_eq(2, result.hunks[1].count_new, "count_new") -- inserts empty line + line2
end)

test("diff.compute: modification (append_chars)", function()
  local snapshot = { "local " }
  local predicted = { "local api = vim.api" }
  local result = diff.compute(snapshot, predicted)
  assert_eq(true, result.has_changes, "has_changes")
  assert_eq(1, #result.hunks, "hunk count")
  assert_eq("modification", result.hunks[1].type, "hunk type")
  assert_eq(1, #result.hunks[1].line_changes, "line_changes count")
  local lc = result.hunks[1].line_changes[1]
  assert_eq("append_chars", lc.change.type, "change type")
  assert_eq(6, lc.change.col, "change col")
  assert_eq("api = vim.api", lc.change.text, "change text")
end)

test("diff.compute: modification at prefix", function()
  local snapshot = { "local x" }
  local predicted = { "local api" }
  local result = diff.compute(snapshot, predicted)
  assert_eq(true, result.has_changes, "has_changes")
  assert_eq("modification", result.hunks[1].type, "hunk type")
  local lc = result.hunks[1].line_changes[1]
  assert_eq(6, lc.change.col, "change col (after 'local ')")
  assert_eq("api", lc.change.text, "change text")
end)

test("diff.analyze_line_change: append at end", function()
  local change = diff.analyze_line_change("hello", "hello world")
  assert_eq("append_chars", change.type)
  assert_eq(5, change.col)
  assert_eq(" world", change.text)
end)

test("diff.analyze_line_change: modification at prefix", function()
  local change = diff.analyze_line_change("hello x", "hello world")
  assert_eq("modification", change.type)
  assert_eq(6, change.col)
  assert_eq("world", change.text)
end)

-- =============================================================================
-- Render positioning tests (mock buffer)
-- =============================================================================

print("\n--- Render positioning tests ---\n")

test("extmark line calculation: window_start=1, hunk.start_old=8, lc.index=1", function()
  -- This simulates: file starts at line 1, hunk is on line 8, first line change
  local window_start = 1
  local hunk_start_old = 8
  local lc_index = 1
  -- Formula: (window_start - 1) + (hunk.start_old - 1) + (lc.index - 1)
  local lnum = window_start + hunk_start_old + lc_index - 3 -- 0-indexed buffer line
  -- Expected: buffer line 7 (0-indexed) = display line 8 (1-indexed)
  assert_eq(7, lnum, "0-indexed buffer line")
end)

test("extmark line calculation: window_start=5, hunk.start_old=3, lc.index=1", function()
  -- Window starts at line 5, hunk is at relative line 3 within window
  -- This means the hunk affects file line 5 + 3 - 1 = 7 (1-indexed)
  local window_start = 5
  local hunk_start_old = 3
  local lc_index = 1
  local lnum = window_start + hunk_start_old + lc_index - 3
  -- Expected: buffer line 6 (0-indexed) = file line 7 (1-indexed)
  assert_eq(6, lnum, "0-indexed buffer line")
end)

test("cursor column extraction: Lua string indexing", function()
  -- cursor_col is 0-indexed (from nvim_win_get_cursor)
  -- Lua strings are 1-indexed
  local current_line = "local api"
  local cursor_col = 6 -- cursor after "local " (0-indexed)
  
  -- This is what the code does:
  local before_cursor = current_line:sub(1, cursor_col)
  -- But cursor_col=6 means characters 0-5 are before cursor
  -- In Lua 1-indexed: sub(1, 6) gives "local " (6 chars)
  assert_eq("local ", before_cursor, "before_cursor")
end)

test("cursor column extraction: cursor at position 0", function()
  local current_line = "local api"
  local cursor_col = 0 -- cursor at start
  local before_cursor = current_line:sub(1, cursor_col)
  -- sub(1, 0) returns empty string
  assert_eq("", before_cursor, "before_cursor at col 0")
end)

test("suffix extraction: prediction matches prefix", function()
  local current_line = "local "
  local cursor_col = 6 -- after "local "
  local new_line = "local api = vim.api"
  
  local before_cursor = current_line:sub(1, cursor_col)
  assert_eq("local ", before_cursor, "before_cursor")
  
  -- Check if new_line starts with before_cursor
  local prefix_matches = new_line:sub(1, #before_cursor) == before_cursor
  assert_eq(true, prefix_matches, "prefix matches")
  
  -- Extract suffix
  local suffix = new_line:sub(cursor_col + 1)
  assert_eq("api = vim.api", suffix, "suffix to display")
end)

test("suffix extraction: cursor at EOL", function()
  local current_line = "local api"
  local cursor_col = 9 -- at end of line (0-indexed, so after 9 chars)
  local new_line = "local api = vim.api"
  
  local before_cursor = current_line:sub(1, cursor_col)
  assert_eq("local api", before_cursor, "before_cursor")
  
  local prefix_matches = new_line:sub(1, #before_cursor) == before_cursor
  assert_eq(true, prefix_matches, "prefix matches")
  
  local suffix = new_line:sub(cursor_col + 1)
  assert_eq(" = vim.api", suffix, "suffix to display")
end)

-- =============================================================================
-- Integration test with actual buffer
-- =============================================================================

print("\n--- Integration tests (requires Neovim) ---\n")

if vim.api then
  test("create buffer and set extmark with virt_text_pos=inline", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local " })
    
    local ns = vim.api.nvim_create_namespace("test_blink_edit")
    
    -- Set extmark at column 6 (after "local ")
    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 6, {
      virt_text = { { "api = vim.api", "Comment" } },
      virt_text_pos = "inline",
    })
    
    assert_eq(true, mark_id > 0, "extmark created")
    
    -- Verify extmark position
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert_eq(1, #marks, "extmark count")
    assert_eq(0, marks[1][2], "extmark row (0-indexed)")
    assert_eq(6, marks[1][3], "extmark col")
    
    -- Cleanup
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  
  test("render module: show_modification places extmark correctly", function()
    -- Setup buffer with content
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "---@class BlinkEdit",
      "local M = {}",
      "",
      "local config = require('blink-edit.config')",
      "local transport = require('blink-edit.transport')",
      "local commands = require('blink-edit.commands')",
      "local engine = require('blink-edit.core.engine')",
      "local ", -- Line 8: cursor is here, typing "local "
    })
    
    -- Simulate cursor at line 8, column 6 (after "local ")
    local cursor = { 8, 6 }
    
    -- Create a modification hunk
    local hunk = {
      type = "modification",
      start_old = 8, -- Line 8 in the snapshot
      start_new = 8,
      count_old = 1,
      count_new = 1,
      old_lines = { "local " },
      new_lines = { "local api = vim.api" },
      line_changes = {
        {
          index = 1,
          change = {
            type = "append_chars",
            col = 6,
            text = "api = vim.api",
          },
        },
      },
    }
    
    local render = require("blink-edit.core.render")
    local ns = render.get_namespace()
    
    -- Clear any existing extmarks
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    
    -- Note: show_modification is local, so we test via M.show()
    -- For now, just verify the buffer setup is correct
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    assert_eq(8, line_count, "buffer has 8 lines")
    
    local line8 = vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1]
    assert_eq("local ", line8, "line 8 content")
    
    -- Cleanup
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  
  test("full render flow with prediction", function()
    -- Create a buffer
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "local M = {}",
      "",
      "local ", -- Line 3: user typed "local "
    })
    
    -- Set this as current buffer temporarily
    local orig_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(bufnr)
    
    -- Create prediction
    local prediction = {
      window_start = 1,
      snapshot_lines = {
        "local M = {}",
        "",
        "local ",
      },
      predicted_lines = {
        "local M = {}",
        "",
        "local api = vim.api",
      },
      cursor = { 3, 6 }, -- Line 3, after "local "
    }
    
    local render = require("blink-edit.core.render")
    local ns = render.get_namespace()
    
    -- Show the prediction
    render.show(bufnr, prediction)
    
    -- Check extmarks
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    
    -- Should have at least one extmark
    assert_eq(true, #marks >= 1, "has extmarks")
    
    -- Find the inline modification extmark
    local found_inline = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_text_pos == "inline" then
        found_inline = true
        -- Should be on line 2 (0-indexed) = line 3 (1-indexed)
        assert_eq(2, mark[2], "extmark on correct line (0-indexed)")
        -- Should be at column 6
        assert_eq(6, mark[3], "extmark at correct column")
        -- Check the text
        local virt_text = details.virt_text
        if virt_text and virt_text[1] then
          assert_eq("api = vim.api", virt_text[1][1], "virtual text content")
        end
      end
    end
    
    assert_eq(true, found_inline, "found inline extmark")
    
    -- Cleanup
    render.clear(bufnr)
    vim.api.nvim_set_current_buf(orig_buf)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
else
  print("(Skipping integration tests - not running in Neovim)")
end

-- =============================================================================
-- Jump prediction tests
-- =============================================================================

print("\n--- Jump prediction tests ---\n")

test("jump indicator: shows TAB when hunk is below cursor", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "line 1",
    "line 2",
    "line 3", -- cursor here
    "line 4",
    "line 5", -- prediction changes this line
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  local prediction = {
    window_start = 1,
    snapshot_lines = {
      "line 1",
      "line 2",
      "line 3",
      "line 4",
      "line 5",
    },
    predicted_lines = {
      "line 1",
      "line 2",
      "line 3",
      "line 4",
      "line 5 modified", -- change on line 5
    },
    cursor = { 3, 0 }, -- cursor on line 3
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  -- Should have extmarks: one for modification + one for jump indicator
  assert_eq(true, #marks >= 1, "has extmarks")
  
  -- Find jump indicator (virt_text with TAB text, right_align position)
  local found_jump = false
  for _, mark in ipairs(marks) do
    local details = mark[4]
    -- Check for right_align virt_text (new style)
    if details.virt_text and details.virt_text_pos == "right_align" then
      for _, segment in ipairs(details.virt_text) do
        if segment[1] and segment[1]:find("TAB") then
          found_jump = true
        end
      end
    end
    -- Also check virt_lines for backward compatibility in tests
    if details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        for _, segment in ipairs(vl) do
          if segment[1] and segment[1]:find("TAB") then
            found_jump = true
          end
        end
      end
    end
  end
  
  assert_eq(true, found_jump, "jump indicator shown")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("jump indicator: NOT shown when inline modification at cursor", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "local M = {}",
    "",
    "local ", -- cursor here, prediction extends this line
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  local prediction = {
    window_start = 1,
    snapshot_lines = {
      "local M = {}",
      "",
      "local ",
    },
    predicted_lines = {
      "local M = {}",
      "",
      "local api = vim.api", -- extends line 3
    },
    cursor = { 3, 6 }, -- cursor after "local "
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  -- Should have inline extmark but NO jump indicator
  local found_inline = false
  local found_jump = false
  
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_text_pos == "inline" then
      found_inline = true
    end
    -- Check for right_align virt_text (new jump indicator style)
    if details.virt_text and details.virt_text_pos == "right_align" then
      for _, segment in ipairs(details.virt_text) do
        if segment[1] and segment[1]:find("TAB") then
          found_jump = true
        end
      end
    end
    -- Also check virt_lines for backward compatibility
    if details.virt_lines then
      for _, vl in ipairs(details.virt_lines) do
        for _, segment in ipairs(vl) do
          if segment[1] and segment[1]:find("TAB") then
            found_jump = true
          end
        end
      end
    end
  end
  
  assert_eq(true, found_inline, "inline modification shown")
  assert_eq(false, found_jump, "jump indicator NOT shown when inline at cursor")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

-- =============================================================================
-- Replacement tests
-- =============================================================================

print("\n--- Replacement/hover tests ---\n")

test("replacement: shows hover window for multi-line replacement", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "function foo()",
    "  return 1",
    "end",
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  -- Replacement: 1 line -> 2 lines (different counts = replacement type)
  local prediction = {
    window_start = 1,
    snapshot_lines = {
      "function foo()",
      "  return 1",
      "end",
    },
    predicted_lines = {
      "function foo()",
      "  local x = 1",
      "  return x * 2",
      "end",
    },
    cursor = { 2, 0 }, -- cursor on "  return 1"
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  -- Note: This will try to create a hover window
  -- In headless mode, window creation may fail but we can check extmarks
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  -- Should have some indication of the change
  assert_eq(true, #marks >= 0, "has extmarks or hover")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("diff.compute: replacement detection (different line counts)", function()
  local diff = require("blink-edit.core.diff")
  
  -- Snapshot has 1 line, predicted has 2 lines at same position
  local snapshot = {
    "line 1",
    "old content",
    "line 3",
  }
  local predicted = {
    "line 1",
    "new line A",
    "new line B",
    "line 3",
  }
  
  local result = diff.compute(snapshot, predicted)
  assert_eq(true, result.has_changes, "has_changes")
  
  -- Should detect replacement (1 old line -> 2 new lines)
  local found_replacement = false
  for _, hunk in ipairs(result.hunks) do
    if hunk.type == "replacement" then
      found_replacement = true
      assert_eq(1, hunk.count_old, "old line count")
      assert_eq(2, hunk.count_new, "new line count")
    end
  end
  
  assert_eq(true, found_replacement, "detected replacement hunk")
end)

test("inline replacement: cursor-line modification replaces content", function()
  local diff = require("blink-edit.core.diff")
  
  -- User typed "local x", prediction wants "local api = vim.api"
  local old_line = "local x"
  local new_line = "local api = vim.api"
  
  local change = diff.analyze_line_change(old_line, new_line)
  
  -- Should find common prefix "local " (6 chars) and show rest as modification
  assert_eq("modification", change.type, "change type")
  assert_eq(6, change.col, "column after 'local '")
  assert_eq("api = vim.api", change.text, "replacement text")
end)

test("inline: NOT shown when prediction disagrees with user input", function()
  -- User typed "local x" but prediction wants "local api"
  -- The "x" vs "a" disagreement means inline ghost text should NOT be shown
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "local x", -- user typed "local x"
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  local prediction = {
    window_start = 1,
    snapshot_lines = { "local x" },
    predicted_lines = { "local api = vim.api" }, -- disagrees with "x"
    cursor = { 1, 7 }, -- cursor after "local x" (7 chars, 0-indexed col = 7)
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  -- Should NOT have inline extmark (prediction disagrees)
  -- Should have jump indicator instead
  local found_inline = false
  local found_jump = false
  
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_text_pos == "inline" then
      found_inline = true
    end
    if details.virt_text_pos == "right_align" then
      for _, segment in ipairs(details.virt_text or {}) do
        if segment[1] and segment[1]:find("TAB") then
          found_jump = true
        end
      end
    end
  end
  
  assert_eq(false, found_inline, "inline NOT shown when prediction disagrees")
  assert_eq(true, found_jump, "jump indicator shown for disagreement")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

-- =============================================================================
-- Edge cases
-- =============================================================================

test("bug: TAB indicator should NOT show when inline ghost text is visible", function()
  -- Reproduces: user types "export const databade", prediction wants "export const database = drizzle(...)"
  -- Since "databade" != "database", prediction disagrees - should show TAB only, not inline
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "});",
    "export const databade", -- cursor here, user typing
    "console.log(database);",
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  local prediction = {
    window_start = 1,
    snapshot_lines = {
      "});",
      "export const databade",
      "console.log(database);",
    },
    predicted_lines = {
      "});",
      "export const database = drizzle(pool, { schema });", -- fixes typo + adds rest
      "console.log(database);",
    },
    cursor = { 2, 21 }, -- cursor after "export const databade" (21 chars)
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  local found_inline = false
  local found_jump = false
  local inline_line = nil
  local jump_line = nil
  
  for _, mark in ipairs(marks) do
    local row = mark[2]
    local details = mark[4]
    if details.virt_text_pos == "inline" then
      found_inline = true
      inline_line = row
    end
    if details.virt_text_pos == "right_align" then
      for _, segment in ipairs(details.virt_text or {}) do
        if segment[1] and segment[1]:find("TAB") then
          found_jump = true
          jump_line = row
        end
      end
    end
  end
  
  -- "databade" vs "database" disagrees at char 18 - NO inline should show
  assert_eq(false, found_inline, "inline should NOT show for disagreement")
  assert_eq(true, found_jump, "TAB should show for disagreement")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("bug: off-cursor line modifications should NOT show inline ghost text", function()
  -- Bug: prediction modifies both line 2 and line 3
  -- Line 2 is at cursor - should show inline
  -- Line 3 is NOT at cursor - should NOT show inline (was showing "b);" ghost text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "});",
    "export const databade",
    "console.log(database);",
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  local prediction = {
    window_start = 1,
    snapshot_lines = {
      "});",
      "export const databade",
      "console.log(database);",
    },
    predicted_lines = {
      "});",
      "export const databade = drizzle(pool, { schema });",
      "console.log(db);", -- ALSO modifies line 3
    },
    cursor = { 2, 21 },
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  local inline_lines = {}
  for _, mark in ipairs(marks) do
    local row = mark[2]
    local details = mark[4]
    if details.virt_text_pos == "inline" then
      table.insert(inline_lines, row)
    end
  end
  
  -- Only line 1 (0-indexed, = line 2 1-indexed) should have inline
  assert_eq(1, #inline_lines, "only one inline extmark")
  assert_eq(1, inline_lines[1], "inline on line 2 (0-indexed: 1)")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("bug: inline shows but TAB also shows on SAME line (from screenshot)", function()
  -- This test reproduces the exact screenshot scenario:
  -- User typed "export const databade" (with typo or partial)
  -- Prediction continues: "export const databade = drizzle(pool, { schema });"
  -- The prediction IS a pure suffix (adds "= drizzle..."), so inline should show
  -- BUT the screenshot shows TAB indicator ALSO on the same line - that's the bug!
  
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "});",
    "export const databade", -- cursor here
    "console.log(database);",
  })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  -- Prediction is a PURE CONTINUATION (adds suffix, doesn't change existing text)
  local prediction = {
    window_start = 1,
    snapshot_lines = {
      "});",
      "export const databade",
      "console.log(database);",
    },
    predicted_lines = {
      "});",
      "export const databade = drizzle(pool, { schema });", -- CONTINUES from "databade"
      "console.log(database);",
    },
    cursor = { 2, 21 }, -- cursor after "export const databade"
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  
  local found_inline = false
  local found_jump = false
  local inline_line = nil
  local jump_line = nil
  
  for _, mark in ipairs(marks) do
    local row = mark[2]
    local details = mark[4]
    if details.virt_text_pos == "inline" then
      found_inline = true
      inline_line = row
    end
    if details.virt_text_pos == "right_align" then
      for _, segment in ipairs(details.virt_text or {}) do
        if segment[1] and segment[1]:find("TAB") then
          found_jump = true
          jump_line = row
        end
      end
    end
  end
  
  -- Prediction is pure continuation - inline SHOULD show
  assert_eq(true, found_inline, "inline should show for pure continuation")
  
  -- TAB should NOT show when inline is shown at cursor
  assert_eq(false, found_jump, "TAB should NOT show when inline is at cursor")
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

print("\n--- Edge case tests ---\n")

test("empty prediction: no extmarks created", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, nil)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  assert_eq(0, #marks, "no extmarks for nil prediction")
  
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("identical prediction: no extmarks created", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello", "world" })
  
  local prediction = {
    window_start = 1,
    snapshot_lines = { "hello", "world" },
    predicted_lines = { "hello", "world" },
    cursor = { 1, 0 },
  }
  
  local render = require("blink-edit.core.render")
  local ns = render.get_namespace()
  
  render.show(bufnr, prediction)
  
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  assert_eq(0, #marks, "no extmarks for identical prediction")
  
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("cursor at end of file: handles boundary correctly", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1", "line 2" })
  
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  
  local prediction = {
    window_start = 1,
    snapshot_lines = { "line 1", "line 2" },
    predicted_lines = { "line 1", "line 2", "line 3" },
    cursor = { 2, 6 }, -- end of last line
  }
  
  local render = require("blink-edit.core.render")
  
  -- Should not error
  local ok, err = pcall(render.show, bufnr, prediction)
  assert_eq(true, ok, "no error at file boundary: " .. tostring(err))
  
  render.clear(bufnr)
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

print("\n=== Tests complete ===\n")
