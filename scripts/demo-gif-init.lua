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

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h")

vim.g.mapleader = " "
vim.o.number = true
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.laststatus = 0
pcall(vim.cmd.colorscheme, "habamax")

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/harnt.lua")
require("harnt").setup()

local AGENT = vim.env.HARNT_DEMO_AGENT or "antigravity"
local SCENARIO = vim.env.HARNT_DEMO_SCENARIO or "accept"
local PROMPT =
  "Fix the off-by-one bug in fizzbuzz.lua so it prints through n. Make the edit, then stop."

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
    local c = base(session)
    c[#c + 1] = PROMPT
    return c
  end
elseif AGENT == "codex" then
  local codex = require("harnt.providers.codex")
  local base = codex.cmd
  codex.cmd = function(session)
    local c = base(session)
    -- `approval_policy=untrusted` makes codex REQUEST approval before editing, so
    -- the app-server sends `item/fileChange/requestApproval` — which harnt taps
    -- and turns into the diff. Without it codex auto-applies and there's nothing
    -- to gate. (Demo config; the provider itself respects the user's own policy.)
    c[#c + 1] = "-c"
    c[#c + 1] = "approval_policy=untrusted"
    c[#c + 1] = PROMPT
    return c
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
    -- show a comment, then submit the review (reject + feedback to the agent)
    vim.defer_fn(function()
      diff.add_comment(id, 1, "keep the loop bound obvious — off-by-one here")
    end, 900)
    vim.defer_fn(function()
      manager.review(id)
    end, DWELL + 1100)
  else
    vim.defer_fn(function()
      diff.accept(id)
      if SCENARIO == "changelog" then
        -- after the change is recorded, open the read-only change-log view
        vim.defer_fn(function()
          if changes.count() > 0 then
            changes.open(changes.count())
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
  manager.launch(AGENT)
end, 800)
