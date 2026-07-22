---@diagnostic disable
-- Parameterized init for recording the README demo GIFs (via scripts/demo.tape +
-- vhs). One harness records every variant; env selects which:
--   HARNT_DEMO_AGENT    = antigravity | claude | codex   (default antigravity)
--   HARNT_DEMO_SCENARIO = accept | review | changelog     (default accept)
--
-- Clean Neovim, harnt loaded, dropped into a fresh temp git project seeded with a
-- genuinely buggy fizzbuzz.lua. The chosen agent launches with the task as an
-- initial prompt (so the take needs no typing into the agent's TUI), and harnt
-- RESPONDS TO THE DIFF OPENING — a readable beat after the diff appears it acts
-- the way the review keys do (accept, or comment+reject for `review`). Timing is
-- driven by the actual open event, so every take is tight regardless of model
-- latency — no sleep-guessing, no post-hoc frame cutting.
--
-- The UI is dressed for the camera: a self-contained Catppuccin-Mocha highlight
-- set (matching the vhs terminal theme, no plugins) and a full-width narration bar
-- (the tabline) that captions each beat so a first-time viewer follows the flow.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h")

vim.g.mapleader = " "
vim.o.number = true
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.signcolumn = "yes"
vim.o.cursorline = true
vim.o.fillchars = "eob: ,vert:│"

-- A small, self-contained Catppuccin-Mocha palette applied as highlight overrides
-- (no colorscheme plugin, so `just demo` reproduces this anywhere). Matches the
-- terminal theme the tape sets, so the split looks like one cohesive UI.
local c = {
  base = "#1e1e2e",
  mantle = "#181825",
  text = "#cdd6f4",
  subtext = "#a6adc8",
  overlay = "#6c7086",
  surface0 = "#313244",
  surface1 = "#45475a",
  green = "#a6e3a1",
  red = "#f38ba8",
  yellow = "#f9e2af",
  blue = "#89b4fa",
  mauve = "#cba6f7",
  peach = "#fab387",
}
pcall(vim.cmd.colorscheme, "habamax") -- neutral base we then override
local function hl(group, opts)
  vim.api.nvim_set_hl(0, group, opts)
end
hl("Normal", { fg = c.text, bg = c.base })
hl("NormalNC", { fg = c.text, bg = c.base })
hl("LineNr", { fg = c.overlay, bg = c.base })
hl("CursorLine", { bg = c.surface0 })
hl("CursorLineNr", { fg = c.peach, bg = c.surface0, bold = true })
hl("SignColumn", { bg = c.base })
hl("Comment", { fg = c.overlay, italic = true })
hl("String", { fg = c.green })
hl("Function", { fg = c.blue })
hl("Keyword", { fg = c.mauve })
hl("Number", { fg = c.peach })
hl("WinSeparator", { fg = c.surface1, bg = c.base })
-- Diff colors (used by the side-by-side presenter + the filetype=diff view).
hl("DiffAdd", { fg = c.green, bg = "#26332b" })
hl("DiffDelete", { fg = c.red, bg = "#3a2730" })
hl("DiffChange", { bg = "#2a2b3d" })
hl("DiffText", { fg = c.yellow, bg = "#3d3a26", bold = true })
hl("diffAdded", { fg = c.green })
hl("diffRemoved", { fg = c.red })
hl("diffLine", { fg = c.blue, bold = true })
-- The diff winbar affordance.
hl("WinBar", { fg = c.base, bg = c.blue, bold = true })
hl("WinBarNC", { fg = c.base, bg = c.blue, bold = true })

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/harnt.lua")
require("harnt").setup()

local AGENT = vim.env.HARNT_DEMO_AGENT or "antigravity"
local SCENARIO = vim.env.HARNT_DEMO_SCENARIO or "accept"
local PROMPT =
  "Fix the off-by-one bug in fizzbuzz.lua so it prints through n. Make the edit, then stop."

local AGENT_LABEL = ({ antigravity = "Antigravity", claude = "Claude Code", codex = "Codex" })[AGENT]
  or AGENT

-- ── Narration bar ─────────────────────────────────────────────────────────────
-- A full-width tabline caption that names what's happening. Always visible, never
-- overlaps the split. Updated at each beat below.
hl("HarntCap", { fg = c.text, bg = c.mantle })
hl("HarntCapAccent", { fg = c.base, bg = c.mauve, bold = true })
hl("HarntCapKey", { fg = c.peach, bg = c.mantle, bold = true })

local caption = ""
-- selene: allow(global_usage)
-- `v:lua` resolves the tabline callback from the global table, so it must be one.
function _G.HarntDemoTabline()
  local width = vim.o.columns
  local badge = "%#HarntCapAccent# harnt.nvim %#HarntCap# "
  -- rough centering of the caption in the remaining space
  local plain = caption:gsub("%%#%w+#", "")
  local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(plain) - 13) / 2))
  return badge .. string.rep(" ", pad) .. caption
end
vim.o.showtabline = 2
vim.o.tabline = "%!v:lua.HarntDemoTabline()"
local function say(text)
  caption = text
  vim.cmd.redrawtabline()
end
say("every agent, one diff flow — in Neovim")

-- Launch each agent with the task as an initial prompt. Each keeps its own launch
-- shape; we only append the prompt (agy takes -i, claude/codex take a positional).
if AGENT == "antigravity" then
  -- accept-edits disables agy's OWN prompt so harnt's diff is the single gate
  -- (proven real both ways by just e2e-agy-hooks).
  require("harnt.providers.antigravity").cmd =
    { "agy", "--new-project", "--mode", "accept-edits", "-i", PROMPT }
elseif AGENT == "claude" then
  local claude = require("harnt.providers.claude")
  local base = claude.cmd
  claude.cmd = function(session)
    local cmd = base(session)
    cmd[#cmd + 1] = PROMPT
    return cmd
  end
elseif AGENT == "codex" then
  local codex = require("harnt.providers.codex")
  local base = codex.cmd
  codex.cmd = function(session)
    local cmd = base(session)
    -- `approval_policy=untrusted` makes codex REQUEST approval before editing, so
    -- the app-server sends `item/fileChange/requestApproval` — which harnt taps
    -- and turns into the diff. Without it codex auto-applies and there's nothing
    -- to gate. (Demo config; the provider itself respects the user's own policy.)
    cmd[#cmd + 1] = "-c"
    cmd[#cmd + 1] = "approval_policy=untrusted"
    cmd[#cmd + 1] = PROMPT
    return cmd
  end
end

-- Respond to the diff opening. Only the first diff is driven (so a rejected edit
-- that the agent re-proposes doesn't loop).
local diff = require("harnt.services.diff")
local manager = require("harnt.manager")
local changes = require("harnt.services.changes")
local DWELL = 3000 -- ms the diff is on screen before we act, so it's clearly readable
local handled = false

local function drive(id)
  if handled then
    return
  end
  handled = true
  if SCENARIO == "review" then
    say("Review it: comment on a line, then send it back as feedback")
    -- show a comment, then submit the review (reject + feedback to the agent)
    vim.defer_fn(function()
      diff.add_comment(id, 1, "keep the loop bound obvious — off-by-one here")
      say(
        "%#HarntCapKey#<leader>c%#HarntCap# comment    %#HarntCapKey#<leader>R%#HarntCap# submit review"
      )
    end, 900)
    vim.defer_fn(function()
      manager.review(id)
      say("↩ feedback sent — the agent revises in its own TUI")
    end, DWELL + 1100)
  else
    say(
      "%#HarntCapKey#<leader>a%#HarntCap# accept    %#HarntCapKey#<leader>r%#HarntCap# reject    the diff — shown in Neovim, not a chat box"
    )
    vim.defer_fn(function()
      diff.accept(id)
      say("✓ applied — the agent keeps working in its own TUI")
      if SCENARIO == "changelog" then
        -- after the change is recorded, open the read-only change-log view
        vim.defer_fn(function()
          if changes.count() > 0 then
            changes.open(changes.count())
            say("%#HarntCapKey#:Harnt changes%#HarntCap# — every edit this session, one log")
          end
        end, 1600)
      end
    end, DWELL)
  end
end

local function wrap(open)
  return function(spec, cb)
    local id = open(spec, cb)
    drive(id)
    return id
  end
end
diff.open = wrap(diff.open)
diff.open_review = wrap(diff.open_review)
require("harnt.services.approvals").set_chooser(function(_req, on_choice)
  on_choice("allow_once")
end)

-- Seed a fresh project with a real off-by-one bug (misses n).
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.system({ "git", "-C", dir, "init", "-q" })
local sample = dir .. "/fizzbuzz.lua"
vim.fn.writefile({
  "-- Print FizzBuzz for 1..n.",
  "local function fizzbuzz(n)",
  "  for i = 1, n - 1 do -- BUG: off by one, never prints n",
  "    if i % 15 == 0 then",
  '      print("FizzBuzz")',
  "    elseif i % 3 == 0 then",
  '      print("Fizz")',
  "    elseif i % 5 == 0 then",
  '      print("Buzz")',
  "    else",
  "      print(i)",
  "    end",
  "  end",
  "end",
  "",
  "fizzbuzz(15)",
}, sample)
vim.cmd.cd(dir)
vim.cmd.edit(sample)

-- Launch the agent once nvim has painted, so the tape is agent-agnostic.
vim.defer_fn(function()
  say(("▶ %s is proposing a fix…"):format(AGENT_LABEL))
  manager.launch(AGENT)
end, 800)
