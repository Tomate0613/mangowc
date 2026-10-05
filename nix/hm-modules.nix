self:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.wayland.windowManager.mango;
  variables = lib.concatStringsSep " " cfg.systemd.variables;
  extraCommands = lib.concatStringsSep " && " cfg.systemd.extraCommands;
  systemdActivation = "${pkgs.dbus}/bin/dbus-update-activation-environment --systemd ${variables}; ${extraCommands}";
  autostart_sh = pkgs.writeShellScript "autostart.sh" ''
    ${lib.optionalString cfg.systemd.enable systemdActivation}
    ${cfg.autostart_sh}
  '';
  writeTOML = (pkgs.formats.toml { }).generate;
in
{
  options = {
    wayland.windowManager.mango = with lib; {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to enable mangowm, a Wayland compositor based on dwl.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.mango;
        description = "The mango package to use";
      };
      systemd = {
        enable = mkOption {
          type = types.bool;
          default = pkgs.stdenv.hostPlatform.isLinux;
          example = false;
          description = ''
            Whether to enable {file}`mango-session.target` on
            mango startup. This links to
            {file}`graphical-session.target`.
            Some important environment variables will be imported to systemd
            and dbus user environment before reaching the target, including
            * {env}`DISPLAY`
            * {env}`WAYLAND_DISPLAY`
            * {env}`XDG_CURRENT_DESKTOP`
            * {env}`XDG_SESSION_TYPE`
            * {env}`NIXOS_OZONE_WL`
            You can extend this list using the `systemd.variables` option.
          '';
        };
        variables = mkOption {
          type = types.listOf types.str;
          default = [
            "DISPLAY"
            "WAYLAND_DISPLAY"
            "XDG_CURRENT_DESKTOP"
            "XDG_SESSION_TYPE"
            "NIXOS_OZONE_WL"
            "XCURSOR_THEME"
            "XCURSOR_SIZE"
          ];
          example = [ "--all" ];
          description = ''
            Environment variables imported into the systemd and D-Bus user environment.
          '';
        };
        extraCommands = mkOption {
          type = types.listOf types.str;
          default = [
            "systemctl --user reset-failed"
            "systemctl --user start mango-session.target"
          ];
          description = ''
            Extra commands to run after D-Bus activation.
          '';
        };
        xdgAutostart = mkEnableOption ''
          autostart of applications using
          {manpage}`systemd-xdg-autostart-generator(8)`
        '';
      };
      settings = mkOption {
        type =
          with lib.types;
          let
            valueType =
              nullOr (oneOf [
                bool
                int
                float
                str
                path
                (attrsOf valueType)
                (listOf valueType)
              ])
              // {
                description = "Mango configuration value";
              };
          in
          valueType;
        default = { };
        description = ''
          Mango configuration written in Nix. Entries with the same key
          should be written as lists. Variables and colors names should be
          quoted. See <https://mangowm.github.io/docs> for more examples.

          ::: {.note}
          This option uses a structured format that is converted to Mango's
          configuration syntax. Nested attributes are flattened with underscore separators.
          For example: `animation.duration_open = 400` becomes `animation_duration_open = 400`

          Keymodes (submaps) are supported via the special `key_mode` attribute. Each key_mode
          is a nested attribute set under `key_mode` that contains its own bindings.
          :::
        '';
        example = lib.literalExpression ''
          {
            global = {
              # Window effects
              blur = 1;
              blur_optimized = 1;
              blur_params_radius = 5;
              blur_params_num_passes = 2;
              border_radius = 6;
              focused_opacity = 1.0;

              # Animations - use underscores for multi-part keys
              animations = 1;
              animation_type_open = "slide";
              animation_type_close = "slide";
              animation_duration_open = 400;
              animation_duration_close = 800;
            };

            bind.default = {
              "SUPER+r" = "reload_config";
              "Alt+space" = "spawn,rofi -show drun";
              "Alt+Return" = "spawn,foot";
              "ALT+R" = "setkeymode,resize"; # Enter resize mode
            };

            rule.tag_rule = [
              {
                id: 1;
                layout_name: "tile";
              }
              {
                id: 2;
                layout_name: "scroller";
              }
            ];
          }
        '';
      };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extra configuration lines to add to `~/.config/mango/config.toml`.
          This is useful for advanced configurations that don't fit the structured
          settings format, or for options that aren't yet supported by the module.
        '';
        example = ''
          # Advanced config that doesn't fit structured format
          special_option = 1
        '';
      };
      autostart_sh = mkOption {
        description = ''
          Shell script to run on mango startup. No shebang needed.

          When this option is set, the script will be written to
          `~/.config/mango/autostart.sh` and an `exec_once` line
          will be automatically added to the config to execute it.
        '';
        type = types.lines;
        default = "";
        example = ''
          waybar &
          dunst &
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      settings =
        cfg.settings
        // lib.optionalAttrs (cfg.autostart_sh != "") {
          global.exec_once = "~/.config/mango/autostart.sh";
        };

      validatedConfig = pkgs.runCommand "mango-config.toml" { } ''
        cp ${writeTOML "mango-config.toml" settings} "$out"

        ${lib.optionalString (cfg.extraConfig != "") ''
          printf '\n%s\n' ${lib.escapeShellArg cfg.extraConfig} >> "$out"
        ''}

        ${cfg.package}/bin/mango -c "$out" -p || exit 1
      '';
    in
    {
      # Backwards compatibility warning for old string-based config
      warnings = lib.optional (builtins.isString cfg.settings) ''
        wayland.windowManager.mango.settings: Using a string for settings is deprecated.
        Please migrate to the new structured attribute set format.
        See the module documentation for examples, or use the 'extraConfig' option for raw config strings.
        The old string format will be removed in a future release.
      '';

      home.packages = [ cfg.package ];
      xdg.configFile = {
        "mango/config.toml" =
          lib.mkIf (cfg.settings != { } || cfg.extraConfig != "" || cfg.autostart_sh != "")
            {
              source = validatedConfig;
            };
        "mango/autostart.sh" = lib.mkIf (cfg.autostart_sh != "") {
          source = autostart_sh;
          executable = true;
        };
      };
      systemd.user.targets.mango-session = lib.mkIf cfg.systemd.enable {
        Unit = {
          Description = "mango compositor session";
          Documentation = [ "man:systemd.special(7)" ];
          BindsTo = [ "graphical-session.target" ];
          Wants = [
            "graphical-session-pre.target"
          ]
          ++ lib.optional cfg.systemd.xdgAutostart "xdg-desktop-autostart.target";
          After = [ "graphical-session-pre.target" ];
          Before = lib.optional cfg.systemd.xdgAutostart "xdg-desktop-autostart.target";
        };
      };
    }
  );
}
