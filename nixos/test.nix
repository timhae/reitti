/*
  Reitti NixOS integration test.

  It covers the following scenarios:
  - Booting the application with a locally created PostgreSQL (PostGIS) and
    Redis instance.
  - Automatic generation of the database password and provisioning of the
    database (role, PostGIS extension).
  - Flyway database migrations creating the schema.
  - The health endpoint reporting UP.
  - The first-run setup wizard setting the administrator password.
  - Logging in through the web interface and opening the timeline.
  - Serving the application through the nginx reverse proxy.

  Scenarios NOT covered by this test:
  - OIDC / single sign-on
  - Federation between instances
  - Data upload / import pipelines
*/
_:
let
  adminPassword = "NixosReittiTest1234.";
in
{
  name = "reitti";

  nodes.machine =
    { ... }:
    {
      imports = [ ./module.nix ];

      services.reitti = {
        enable = true;
        domain = "reitti.test";
        nginx = {
          forceSSL = false;
          enableACME = false;
        };
      };

      virtualisation = {
        memorySize = 4096;
        cores = 4;
      };
    };

  testScript =
    { nodes, ... }:
    let
      dataDir = "/var/lib/reitti";
      version = nodes.machine.services.reitti.package.version;
    in
    ''
      import re
      from datetime import timedelta

      password = "${adminPassword}"
      dataDir = "${dataDir}"

      start_all()

      machine.wait_for_unit("postgresql.service")
      machine.wait_for_unit("postgresql-setup.service")
      machine.wait_for_unit("redis-reitti.service")
      machine.wait_for_unit("reitti-db-setup.service")
      machine.wait_for_unit("reitti.service", timeout=timedelta(minutes=10))
      machine.wait_for_open_port(8080)

      with subtest("the database password is generated and kept private"):
          machine.succeed(f"test -s {dataDir}/secrets/db-password")
          machine.succeed(
              f"""test "$(stat -c %a {dataDir}/secrets/db-password)" = 600"""
          )

      with subtest("the PostGIS extension is installed in the database"):
          machine.succeed(
              "sudo -u postgres psql -d reitti -tAc"
              " \"SELECT extname FROM pg_extension\" | grep -x postgis"
          )

      with subtest("the Flyway migrations created the schema"):
          for table in ["users", "raw_location_points", "flyway_schema_history"]:
              machine.succeed(
                  "sudo -u postgres psql -d reitti -tAc"
                  " \"SELECT tablename FROM pg_tables WHERE schemaname = 'public'\""
                  f" | grep -x {table}"
              )

      with subtest("the health endpoint reports UP"):
          machine.wait_until_succeeds(
              "curl -sSf http://localhost:8080/actuator/health"
              " | grep -q '\"status\":\"UP\"'",
              timeout=timedelta(minutes=5),
          )

      with subtest("the timeline is served through the nginx reverse proxy"):
          machine.wait_for_unit("nginx.service")
          machine.succeed(
              "curl -sSf -H 'Host: reitti.test'"
              " http://localhost/actuator/health > /dev/null"
          )

      with subtest("an unconfigured instance redirects to the setup wizard"):
          status = machine.succeed(
              "curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/"
          ).strip()
          assert status == "302", f"expected redirect, got {status}"
          machine.succeed(
              "curl -sS -o /dev/null -D - http://localhost:8080/"
              " | grep -i '^location:.*/setup'"
          )

      with subtest("the setup wizard sets the administrator password"):
          _, setup_page = machine.execute(
              "curl -sS -c /tmp/setup.cookies http://localhost:8080/setup"
          )
          csrf = re.search(r'name="_csrf"[^>]*value="([^"]+)"', setup_page)
          assert csrf, "csrf token not found on the setup page"
          status = machine.succeed(
              "curl -sS -b /tmp/setup.cookies -c /tmp/setup.cookies -o /dev/null"
              " -w '%{http_code}'"
              + " --data-urlencode _csrf=" + csrf.group(1)
              + " --data-urlencode username=admin"
              + " --data-urlencode password='" + password + "'"
              + " --data-urlencode displayName='Reitti Admin'"
              + " http://localhost:8080/setup"
          ).strip()
          assert status == "302", f"setup failed with status {status}"

      with subtest("the administrator can log in and open the timeline"):
          _, login_page = machine.execute(
              "curl -sS -c /tmp/login.cookies http://localhost:8080/login"
          )
          csrf = re.search(r'name="_csrf"[^>]*value="([^"]+)"', login_page)
          assert csrf, "csrf token not found on the login page"
          status = machine.succeed(
              "curl -sS -b /tmp/login.cookies -c /tmp/login.cookies -o /dev/null"
              " -w '%{http_code}'"
              + " --data-urlencode _csrf=" + csrf.group(1)
              + " --data-urlencode username=admin"
              + " --data-urlencode password='" + password + "'"
              + " http://localhost:8080/login"
          ).strip()
          assert status == "302", f"login failed with status {status}"

          _, timeline = machine.execute(
              "curl -sS -b /tmp/login.cookies http://localhost:8080/"
          )
          assert "settings-btn" in timeline, "timeline page not rendered"

      with subtest("live updates stream through the reverse proxy"):
          # Authenticate through the reverse proxy as well: the session
          # cookie is then issued and used for the proxied origin.
          _, login_page = machine.execute(
              "curl -sS -c /tmp/proxy.cookies -H 'Host: reitti.test'"
              " http://localhost/login"
          )
          csrf = re.search(r'name="_csrf"[^>]*value="([^"]+)"', login_page)
          assert csrf, "csrf token not found on the proxied login page"
          status = machine.succeed(
              "curl -sS -b /tmp/proxy.cookies -c /tmp/proxy.cookies"
              " -H 'Host: reitti.test' -o /dev/null -w '%{http_code}'"
              + " --data-urlencode _csrf=" + csrf.group(1)
              + " --data-urlencode username=admin"
              + " --data-urlencode password='" + password + "'"
              + " http://localhost/login"
          ).strip()
          assert status == "302", f"proxied login failed with status {status}"

          _, proxied_about = machine.execute(
              "curl -sS -b /tmp/proxy.cookies -H 'Host: reitti.test'"
              " http://localhost/settings/about"
          )
          assert "${version}" in proxied_about, (
              "authenticated page not served through the reverse proxy"
          )

          _, proxied_type = machine.execute(
              "curl -sS -N --max-time 3 -o /dev/null -w '%{content_type}'"
              " -b /tmp/proxy.cookies -H 'Host: reitti.test'"
              " http://localhost/events || true"
          )
          assert proxied_type.strip() == "text/event-stream", (
              "proxied SSE endpoint returned %r" % proxied_type
          )

      with subtest("the application version is reported"):
          _, about = machine.execute(
              "curl -sS -b /tmp/login.cookies http://localhost:8080/settings/about"
          )
          assert "${version}" in about, "application version missing on the about page"

      with subtest("the service is stable"):
          machine.succeed(
              "test \"$(systemctl show --property=NRestarts --value reitti.service)\" = 0"
          )
    '';

  interactive.nodes.machine = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    virtualisation.forwardPorts = [
      {
        from = "host";
        host.port = 8080;
        guest.port = 80;
      }
    ];
  };
}
