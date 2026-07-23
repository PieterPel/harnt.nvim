# Dev shell for harnt.nvim — the Lua/Neovim plugin toolchain from docs/TOOLS.md.
# The four-command agent/CI loop (stylua / selene / emmylua_check / busted) is
# fully available here, plus the editor LSPs and a `just` task runner.
{
  perSystem =
    {
      pkgs,
      config,
      lib,
      inputs',
      ...
    }:
    let
      # One shell definition, parametrized by which Neovim it carries. `default`
      # uses nixpkgs' Neovim (tracks the latest stable release via nixos-unstable);
      # `nightly` swaps in the nightly build so CI can run the same gate against
      # both — the stable+nightly matrix from docs/TOOLS.md.
      mkHarntShell =
        neovim:
        pkgs.mkShell {
          # Brings in the git-hooks (pre-commit) tooling so `pre-commit` works in-shell.
          inputsFrom = [ config.pre-commit.devShell ];

          packages = [
            # Task runner — single source of truth for the pipeline (see ./justfile).
            pkgs.just

            # Formatter + linter (docs/TOOLS.md: StyLua, Selene)
            pkgs.stylua
            pkgs.selene

            # Type-checking + LSP — the emmylua-analyzer-rust toolchain.
            # emmylua-check is the CI type gate; emmylua-ls is the primary editor LSP.
            pkgs.emmylua-check
            pkgs.emmylua-ls
            pkgs.emmylua-doc-cli

            # Fallback editor LSP (docs/TOOLS.md: documented escape hatch).
            pkgs.lua-language-server

            # Lua runtimes + packaging (luarocks canonical; lux optional dev ergonomics).
            pkgs.lua5_1
            pkgs.luajit
            pkgs.luarocks
            pkgs.lux-cli

            # Tests: busted with Neovim as the Lua interpreter (via nlua). The
            # Neovim itself is injected so CI can run the same gate on stable + nightly.
            neovim
            pkgs.lua51Packages.busted
            pkgs.lua51Packages.nlua

            # Agent CLIs — pinned so real-CLI e2e verification (scripts/e2e-*.lua)
            # is reproducible. We reverse-engineer each provider's wire by running
            # the real binary against our server.
            pkgs.claude-code
            pkgs.codex
            pkgs.antigravity-cli
            pkgs.opencode # free (MIT); no unfree allowlist entry needed
          ];

          # Export VIMRUNTIME so emmylua (CLI check + LS) can resolve Neovim's Lua
          # runtime and type-check `vim.*` properly (see .luarc.json workspace.library).
          shellHook = ''
            export VIMRUNTIME="$(nvim -l <(printf 'io.write(vim.env.VIMRUNTIME)') 2>/dev/null)"
          '';

          meta.description = lib.mkDefault "harnt.nvim development shell";
        };
    in
    {
      # `nix develop` (stable) and `nix develop .#nightly` — the CI matrix runs
      # `just ci` under each.
      devShells.default = mkHarntShell pkgs.neovim;
      devShells.nightly = mkHarntShell inputs'.neovim-nightly-overlay.packages.default;
    };
}
