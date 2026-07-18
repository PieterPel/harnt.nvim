{ inputs, ... }:
{
  imports = [
    inputs.process-compose-flake.flakeModule
    inputs.actions-nix.flakeModules.default
    inputs.flake-parts.flakeModules.modules
    inputs.treefmt-nix.flakeModule
  ];
}
