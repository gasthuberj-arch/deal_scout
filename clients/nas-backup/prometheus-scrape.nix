{ config, lib, ... }:

with lib;

# NixOS module: configure a Prometheus scrape job for DealScout's
# app-level /metrics endpoint (Bearer-token protected HTTPS).
#
# Add this to your NixOS imports and enable it to have your homelab Prometheus
# scrape custom metrics: backup lag (RPO proxy), boot duration, DB query times,
# Phoenix request rates.
#
# Example configuration.nix usage:
#
#   imports = [ ./clients/nas-backup/prometheus-scrape.nix ];
#
#   services.dealscout-metrics = {
#     enable = true;
#     tokenFile = config.sops.secrets."dealscout/metrics_token".path;
#     # or: token = "your-token";  (not recommended in production)
#   };

let
  cfg = config.services.dealscout-metrics;
in {
  options.services.dealscout-metrics = {
    enable = mkEnableOption "DealScout Prometheus scrape job for homelab Grafana";

    metricsHost = mkOption {
      type = types.str;
      default = "deal-scout.fly.dev";
      description = "Hostname of the DealScout Fly.io app (no scheme, no port).";
    };

    scrapeIntervalSeconds = mkOption {
      type = types.int;
      default = 30;
      description = "How often Prometheus scrapes the /metrics endpoint, in seconds.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file whose sole contents are the METRICS_TOKEN (or ADMIN_BACKUP_TOKEN).
        Recommended: manage with agenix or sops-nix so the secret never lands in the
        Nix store. Exactly one of tokenFile or token must be set.
      '';
    };

    token = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Plaintext metrics token. Prefer tokenFile for production systems.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null || cfg.token != null;
        message = "services.dealscout-metrics: set either tokenFile or token.";
      }
    ];

    # Appended to the Prometheus scrape_configs YAML as a raw string so that
    # the authorization.credentials_file key (which NixOS's structured scrapeConfigs
    # option does not model directly) is supported without workarounds.
    services.prometheus.extraScrapeConfigs = ''
      - job_name: 'dealscout'
        scrape_interval: ${toString cfg.scrapeIntervalSeconds}s
        scheme: https
        metrics_path: /metrics
        static_configs:
          - targets:
              - '${cfg.metricsHost}:443'
            labels:
              app: 'deal-scout'
              env: 'production'
        authorization:
          type: Bearer
          ${if cfg.tokenFile != null
            then "credentials_file: '${toString cfg.tokenFile}'"
            else "credentials: '${cfg.token}'"}
    '';
  };
}
