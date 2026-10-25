{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dealscout-backup;

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  clientScript = pkgs.writeScriptBin "dealscout-backup-client" ''
    #!${pythonEnv}/bin/python3
    ${builtins.readFile ./dealscout_backup_client.py}
  '';
in {
  options.services.dealscout-backup = {
    enable = mkEnableOption "DealScout Outbound Real-time NAS Backup Service";

    serverUrl = mkOption {
      type = types.str;
      default = "https://dealscout.fly.dev";
      description = "URL of the DealScout Phoenix server (HTTP/HTTPS/WS/WSS).";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing the ADMIN_BACKUP_TOKEN (recommended for agenix/sops).";
    };

    token = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Plaintext ADMIN_BACKUP_TOKEN (prefer tokenFile for security).";
    };

    backupDir = mkOption {
      type = types.path;
      default = "/var/lib/dealscout-backup";
      description = "Directory where the Litestream replica files will be stored.";
    };

    archiveDb = mkOption {
      type = types.path;
      default = "${cfg.backupDir}/archive.db";
      defaultText = literalExpression ''"''${config.services.dealscout-backup.backupDir}/archive.db"'';
      description = "Path to the persistent append-only SQLite archive database on the NAS.";
    };

    verifyIntervalHours = mkOption {
      type = types.int;
      default = 24;
      description = "Interval in hours to automatically run litestream restore and sqlite3 PRAGMA integrity_check.";
    };

    user = mkOption {
      type = types.str;
      default = "dealscout-backup";
      description = "User account under which DealScout backup runs.";
    };

    group = mkOption {
      type = types.str;
      default = "dealscout-backup";
      description = "Group under which DealScout backup runs.";
    };
  };

  config = mkIf cfg.enable {
    users.groups.${cfg.group} = {};
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.backupDir;
      createHome = true;
      description = "DealScout Backup Client daemon user";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.dealscout-backup = {
      description = "DealScout Real-Time Outbound NAS Backup Client";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.litestream
        pkgs.sqlite
        pkgs.coreutils
      ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.backupDir;
        Restart = "always";
        RestartSec = "10s";

        # Security sandbox
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = unique [ cfg.backupDir (builtins.dirOf (toString cfg.archiveDb)) ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      script = ''
        ARGS=(
          "--server-url" "${cfg.serverUrl}"
          "--backup-dir" "${cfg.backupDir}"
          "--archive-db" "${cfg.archiveDb}"
          "--verify-interval-hours" "${toString cfg.verifyIntervalHours}"
        )

        ${optionalString (cfg.tokenFile != null) ''
          ARGS+=("--token-file" "${toString cfg.tokenFile}")
        ''}

        ${optionalString (cfg.token != null && cfg.tokenFile == null) ''
          ARGS+=("--token" "${cfg.token}")
        ''}

        exec ${clientScript}/bin/dealscout-backup-client "''${ARGS[@]}"
      '';
    };
  };
}
