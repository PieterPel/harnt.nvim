# The plugin itself, packaged so a consuming flake (e.g. a dotfiles repo) can
# reference `harnt-nvim.packages.${system}.default` directly instead of a
# manual `rtp:prepend` — pure Lua, no build step, `vimUtils.buildVimPlugin`
# just lays `plugin/`+`lua/` out in the shape Neovim expects.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.vimUtils.buildVimPlugin {
        pname = "harnt.nvim";
        # release-please owns this file — always the last released version,
        # not a hand-maintained duplicate of it.
        version = (builtins.fromJSON (builtins.readFile ../.release-please-manifest.json)).".";
        src = ../.;

        meta = with pkgs.lib; {
          description = "Drive any native-TUI coding agent in Neovim at full fidelity via reverse-MCP.";
          homepage = "https://github.com/PieterPel/harnt.nvim";
          license = licenses.mit;
          platforms = platforms.unix;
        };
      };
    };
}
