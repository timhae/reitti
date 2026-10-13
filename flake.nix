{
  description = "Reitti - personal location tracking and analysis (package, NixOS module and tests)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = final: _prev: {
        reitti = final.callPackage ./nix/package.nix { };
      };

      nixosModules = rec {
        reitti =
          { pkgs, lib, ... }:
          {
            imports = [ ./nixos/module.nix ];
            services.reitti.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.reitti;
          };
        default = reitti;
      };

      packages = forAllSystems (system: rec {
        inherit (mkPkgs system) reitti;
        default = reitti;
      });

      formatter = forAllSystems (system: (mkPkgs system).nixfmt);

      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;

          # Returns the generated nginx.conf for a node configuring Reitti and
          # optionally additional nginx settings.
          nginxConfig =
            {
              reitti ? { },
              nginx ? { },
            }:
            (pkgs.nixos {
              imports = [ ./nixos/module.nix ];
              services.reitti = {
                enable = true;
                domain = "reitti.test";
              }
              // reitti;
              services.nginx = nginx;
              security.acme.acceptTerms = true;
              security.acme.certs."main".domain = "reitti.test";
              system.stateVersion = "24.11";
            }).config.environment.etc."nginx/nginx.conf".source;

          mkTlsCheck =
            name: conf:
            pkgs.runCommand "check-reitti-nginx-tls-${name}" { } ''
              grep -Eq 'listen[^;]*:443[^;]*ssl' ${conf}
              grep -q 'ssl_certificate' ${conf}
              grep -q 'server_name reitti.test;' ${conf}
              touch $out
            '';
        in
        rec {
          reitti = pkgs.testers.runNixOSTest ./nixos/test.nix;

          # The vhost must get a :443 listener when TLS is configured through
          # the module options ...
          reitti-nginx-tls = mkTlsCheck "module" (nginxConfig {
            reitti.nginx = {
              useACMEHost = "main";
              forceSSL = true;
            };
          });

          # ... and when it is configured through the standard nginx option,
          # which the module must not override.
          reitti-nginx-tls-vhost = mkTlsCheck "vhost" (nginxConfig {
            nginx.virtualHosts."reitti.test" = {
              useACMEHost = "main";
              forceSSL = true;
            };
          });

          default = reitti;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              maven
              openjdk25
              jq
              xmlstarlet
              nixfmt
            ];
          };
        }
      );
    };
}
