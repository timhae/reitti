{
  lib,
  maven,
  openjdk25,
  jre25_minimal,
  xmlstarlet,
  makeWrapper,
}:

let
  # The application is built from this repository. Development, CI and Nix
  # files are stripped so that the build only sees the Maven project. The
  # application source lives in src/main, everything else is packaging.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference (lib.fileset.unions [ ../. ]) (
      lib.fileset.unions (
        map lib.fileset.maybeMissing [
          ../.direnv
          ../.dockerignore
          ../.git
          ../.github
          ../.gitignore
          ../.vscode
          ../CODE_OF_CONDUCT.md
          ../CONVENTIONS.md
          ../DOCKER-HUB-DESCRIPTION.md
          ../Dockerfile
          ../docker
          ../docker-compose-dev.yml
          ../docker-compose-minimal.yml
          ../docker-compose.yml
          ../docs
          ../flake.lock
          ../flake.nix
          ../nix
          ../nixos
          ../result
          ../target
        ]
      )
    );
  };

  # Spring Boot and the application require more modules than the default
  # "java.base". The list mirrors what the official Docker image (full
  # eclipse-temurin JRE) provides for this application.
  jre = jre25_minimal.override {
    modules = [
      "java.base"
      "java.compiler"
      "java.datatransfer"
      "java.desktop"
      "java.instrument"
      "java.logging"
      "java.management"
      "java.naming"
      "java.net.http"
      "java.prefs"
      "java.rmi"
      "java.scripting"
      "java.security.jgss"
      "java.security.sasl"
      "java.sql"
      "java.sql.rowset"
      "java.xml"
      "java.xml.crypto"
      "jdk.crypto.cryptoki"
      "jdk.crypto.ec"
      "jdk.jfr"
      "jdk.management"
      "jdk.net"
      "jdk.unsupported"
    ];
  };
in
maven.buildMavenPackage (finalAttrs: {
  pname = "reitti";
  version = "5.6.1";
  inherit src;

  __structuredAttrs = true;
  strictDeps = true;

  mvnJdk = openjdk25;
  mvnHash = "sha256-3RDxMxDJtdypIYNGdnOS6TxQqxUo/otNbAYC0EHRXj4=";
  doCheck = false;

  mvnParameters = lib.escapeShellArgs [
    "-Dmaven.test.skip=true"
    "-DskipTests"
    "-Dmaven.gitcommitid.skip=true"
  ];

  nativeBuildInputs = [
    xmlstarlet
    makeWrapper
  ];

  postPatch = ''
    # The git-commit-id, surefire and jacoco plugins need a git repository,
    # a working test setup or a JVM agent. They are not needed to build the
    # application, so drop them and provide a static git.properties instead.
    NS="http://maven.apache.org/POM/4.0.0"
    xmlstarlet ed -L -N x="$NS" \
      -d "//x:plugin[x:artifactId='git-commit-id-maven-plugin']" \
      -d "//x:plugin[x:artifactId='maven-surefire-plugin']" \
      -d "//x:plugin[x:artifactId='jacoco-maven-plugin']" \
      pom.xml

    rm -rf src/test

    cat > src/main/resources/git.properties <<EOF
    git.tags=v${finalAttrs.version}
    git.commit.id.abbrev=nix
    git.commit.time=unknown
    git.build.time=unknown
    EOF
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/java
    cp target/*.jar $out/share/java/reitti.jar

    mkdir -p $out/bin
    makeWrapper ${jre}/bin/java $out/bin/reitti \
      --add-flags "-jar $out/share/java/reitti.jar"

    runHook postInstall
  '';

  passthru = {
    inherit jre;
  };
})
