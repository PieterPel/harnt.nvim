{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    {
      # The agent CLIs we pin for real-CLI e2e verification are unfree; allow just
      # those three rather than blanket-enabling unfree.
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (inputs.nixpkgs.lib.getName pkg) [
            "claude-code"
            "codex"
            "antigravity-cli"
          ];
      };
    };
}
