{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.reitti;

  dataDir = "/var/lib/reitti";

  # Password used to authenticate the application against PostgreSQL over
  # TCP. If the user does not provide one and the database is created
  # locally, a random password is generated on first boot instead of being
  # baked into the world-readable Nix store.
  defaultDbPasswordFile = "${dataDir}/secrets/db-password";
  dbPasswordFile =
    if cfg.database.passwordFile != null then cfg.database.passwordFile else defaultDbPasswordFile;
  generateDbPassword = cfg.database.createLocally && cfg.database.passwordFile == null;
  manageDbPassword = cfg.database.createLocally || cfg.database.passwordFile != null;

  # TLS may be configured either through the module options or through the
  # standard services.nginx.virtualHosts.<domain> option; both must be
  # considered for the externally visible URL.
  effectiveVhost = config.services.nginx.virtualHosts.${cfg.domain} or { };
  tlsEnabled =
    cfg.nginx.enable
    && (
      effectiveVhost.enableACME or false
      || effectiveVhost.forceSSL or false
      || (effectiveVhost.useACMEHost or null) != null
    );

  siteUrl =
    if cfg.advertiseUri != null then
      cfg.advertiseUri
    else if cfg.domain != null then
      "${if tlsEnabled then "https" else "http"}://${cfg.domain}"
    else
      "http://${cfg.host}:${toString cfg.port}";

  # The `docker` Spring profile turns the documented POSTGIS_*/REDIS_*
  # environment variables into the corresponding application properties.
  # It also matches the behaviour of the official container image.
  redisEnvironment =
    if cfg.redis.createLocally then
      { REDIS_SOCKET = config.services.redis.servers.reitti.unixSocket; }
    else
      {
        REDIS_HOST = cfg.redis.host;
        REDIS_PORT = toString cfg.redis.port;
      };

  environment = lib.mapAttrs (_: value: toString value) (
    {
      SPRING_PROFILES_ACTIVE = "docker";
      POSTGIS_HOST = cfg.database.host;
      POSTGIS_PORT = toString cfg.database.port;
      POSTGIS_DB = cfg.database.name;
      POSTGIS_USER = cfg.database.user;
      BASE_PATH = cfg.basePath;
      ADVERTISE_URI = siteUrl;
      # No bundled caching tile proxy: talk to the upstream tile service
      # directly unless the user configures one through `environment`.
      TILES_CACHE = "";
      SPATIAL_COVERAGE_LOCATION = "${dataDir}/h3";
    }
    // redisEnvironment
    // cfg.environment
  );

  hardening = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    MemoryDenyWriteExecute = false; # the JVM JIT needs writable/executable memory
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
      "AF_NETLINK"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
    # the JVM writes class data sharing archives into its tmp dir
    UMask = "0027";
  };
in
{
  options.services.reitti = {
    enable = lib.mkEnableOption "Reitti, a personal location tracking and analysis application";

    package = lib.mkPackageOption pkgs "reitti" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "reitti";
      description = "User account under which Reitti runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "reitti";
      description = "Group under which Reitti runs.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Reitti web server listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port the Reitti web server listens on.";
    };

    basePath = lib.mkOption {
      type = lib.types.str;
      default = "/";
      example = "/reitti/";
      description = ''
        Path prefix Reitti is served under. Must start and end with a `/`
        when it is not the root path.
      '';
    };

    advertiseUri = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://reitti.example.org";
      description = ''
        Public URI of the instance, used for federation and magic links.
        Defaults to the URL derived from {option}`services.reitti.domain`.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "reitti.example.org";
      description = "Domain Reitti is served under when nginx is enabled.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
          lib.types.path
        ]
      );
      default = { };
      example = {
        OIDC_ENABLED = "true";
        OIDC_ISSUER_URI = "https://idp.example.org/realms/main";
        OIDC_CLIENT_ID = "reitti";
      };
      description = ''
        Additional environment variables for the Reitti service. See the
        upstream infrastructure documentation for the full list of supported
        variables. Secrets belong in {option}`services.reitti.environmentFile`.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing additional environment variables in systemd
        EnvironmentFile format. Use this for secrets such as
        `OIDC_CLIENT_SECRET`. Keep the file outside the Nix store.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to configure a local PostgreSQL server with the PostGIS
          extension and create the Reitti database. If enabled, the database
          is reachable over TCP on `127.0.0.1`.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "PostgreSQL server host.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL server port.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "reitti";
        description = "Name of the Reitti database.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "reitti";
        description = "PostgreSQL role used by Reitti.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/keys/reitti-db-password";
        description = ''
          File containing the password of the database user. If left at
          `null` while {option}`services.reitti.database.createLocally` is
          enabled, a random password is generated on first boot. Keep the
          file outside the Nix store.
        '';
      };
    };

    redis = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to configure a local Redis server. It is reachable through
          a Unix domain socket.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Redis server host, used when not creating Redis locally.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Redis server port, used when not creating Redis locally.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File containing the Redis password, used when not creating Redis
          locally and Redis requires authentication.
        '';
      };
    };

    nginx = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.domain != null;
        description = "Whether to configure nginx as a reverse proxy.";
      };

      enableACME = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to obtain a TLS certificate using ACME.";
      };

      useACMEHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of an existing ACME certificate to use.";
      };

      forceSSL = lib.mkOption {
        type = lib.types.bool;
        default = cfg.nginx.enableACME;
        description = "Whether to redirect HTTP requests to HTTPS.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.nginx.enable || cfg.domain != null;
        message = "services.reitti.domain must be set when nginx is enabled.";
      }
      {
        assertion = !(cfg.nginx.enableACME && cfg.nginx.useACMEHost != null);
        message = "services.reitti.nginx.enableACME and services.reitti.nginx.useACMEHost are mutually exclusive.";
      }
      {
        assertion = builtins.match "[A-Za-z_][A-Za-z0-9_]*" cfg.database.name != null;
        message = "services.reitti.database.name must be a valid PostgreSQL identifier.";
      }
      {
        assertion = builtins.match "[A-Za-z_][A-Za-z0-9_]*" cfg.database.user != null;
        message = "services.reitti.database.user must be a valid PostgreSQL identifier.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.basePath && lib.hasSuffix "/" cfg.basePath;
        message = "services.reitti.basePath must start and end with a `/`.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "reitti") {
      reitti = {
        isSystemUser = true;
        group = cfg.group;
      };
    };
    users.groups = lib.mkIf (cfg.group == "reitti") { reitti = { }; };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      extensions = ps: [ ps.postgis ];
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers = lib.mkIf cfg.redis.createLocally {
      reitti = {
        enable = true;
        save = [ ];
      };
    };

    systemd.services.reitti-db-setup = lib.mkIf cfg.database.createLocally {
      description = "Prepare the Reitti PostgreSQL database";
      after = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      requires = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      before = [ "reitti.service" ];
      wantedBy = [ "reitti.service" ];
      path = [
        config.services.postgresql.package
        pkgs.openssl
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        install -d -m 0750 -o ${cfg.user} -g ${cfg.group} '${dataDir}' "$(dirname ${dbPasswordFile})"
        ${lib.optionalString generateDbPassword ''
          if [ ! -s ${dbPasswordFile} ]; then
            umask 077
            openssl rand -hex 32 > ${dbPasswordFile}
            chown ${cfg.user}:${cfg.group} ${dbPasswordFile}
          fi
        ''}
        db_password="$(cat ${dbPasswordFile})"

        runuser -u postgres -- psql --no-psqlrc --set ON_ERROR_STOP=1 \
          --dbname='${cfg.database.name}' \
          --set=role='${cfg.database.user}' \
          --set=password="$db_password" <<'SQL'
        SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'password') \gexec
        CREATE EXTENSION IF NOT EXISTS postgis;
        SQL
      '';
    };

    systemd.services.reitti = {
      description = "Reitti - personal location tracking and analysis";
      after = [
        "network.target"
      ]
      ++ lib.optional cfg.database.createLocally "reitti-db-setup.service"
      ++ lib.optional cfg.redis.createLocally "redis-reitti.service";
      requires =
        lib.optional cfg.database.createLocally "reitti-db-setup.service"
        ++ lib.optional cfg.redis.createLocally "redis-reitti.service";
      wantedBy = [ "multi-user.target" ];
      environment = environment;
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = dataDir;
        StateDirectory = "reitti";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "reitti";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = "5min";
        LoadCredential =
          lib.optional manageDbPassword "postgis_password:${dbPasswordFile}"
          ++ lib.optional (cfg.redis.passwordFile != null) "redis_password:${cfg.redis.passwordFile}";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        SupplementaryGroups = lib.mkIf (cfg.redis.createLocally && cfg.user == "reitti") [
          config.services.redis.servers.reitti.group
        ];
        ExecStartPost = [
          "${lib.getExe pkgs.curl} --fail --silent --show-error --retry 60 --retry-delay 5 --retry-all-errors --retry-connrefused http://${cfg.host}:${toString cfg.port}${cfg.basePath}actuator/health"
        ];
      }
      // hardening;
      script = ''
        ${lib.optionalString manageDbPassword ''
          export POSTGIS_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/postgis_password")"
        ''}
        ${lib.optionalString (cfg.redis.passwordFile != null) ''
          export REDIS_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/redis_password")"
        ''}

        exec ${cfg.package}/bin/reitti \
          --server.address='${cfg.host}' \
          --server.port=${toString cfg.port} \
          --reitti.storage.path='${dataDir}' \
          --reitti.h3.path='${dataDir}/h3'
      '';
    };

    services.nginx = lib.mkIf cfg.nginx.enable {
      enable = true;
      virtualHosts."${cfg.domain}" = {
        # mkDefault so the vhost can also be tuned through
        # services.nginx.virtualHosts.<domain>.* (or a global default)
        # without the module overriding it.
        enableACME = lib.mkDefault cfg.nginx.enableACME;
        forceSSL = lib.mkDefault cfg.nginx.forceSSL;
        useACMEHost = lib.mkDefault cfg.nginx.useACMEHost;

        # Values from the upstream reverse proxy guide:
        # https://www.dedicatedcode.com/projects/reitti/latest/infrastructure/reverse-proxy/
        extraConfig = ''
          client_max_body_size 200m;
          client_body_timeout 10m;
          send_timeout 10m;
        '';

        locations = {
          "/" = {
            proxyPass = "http://${cfg.host}:${toString cfg.port}";
            # Sets Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto,
            # X-Forwarded-Host and X-Forwarded-Server as required by Reitti.
            recommendedProxySettings = true;
            extraConfig = ''
              proxy_connect_timeout 60s;
              proxy_send_timeout 10m;
              proxy_read_timeout 10m;

              proxy_request_buffering on;
              proxy_buffering on;
              proxy_buffer_size 4k;
              proxy_buffers 8 4k;
            '';
          };

          # Server-sent events (live updates and log streaming) are long-lived
          # streams and must be passed through without buffering.
          "/events" = {
            proxyPass = "http://${cfg.host}:${toString cfg.port}";
            recommendedProxySettings = true;
            extraConfig = ''
              proxy_buffering off;
              proxy_cache off;
              gzip off;
              proxy_read_timeout 24h;
              proxy_send_timeout 24h;
            '';
          };

          "/settings/logging/stream" = {
            proxyPass = "http://${cfg.host}:${toString cfg.port}";
            recommendedProxySettings = true;
            extraConfig = ''
              proxy_buffering off;
              proxy_cache off;
              gzip off;
              proxy_read_timeout 24h;
              proxy_send_timeout 24h;
            '';
          };
        };
      };
    };
  };
}
