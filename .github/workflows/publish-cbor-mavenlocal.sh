#!/usr/bin/env bash
# Publish the CBOR stack (com.upokecenter:cbor + transitive com.github.peteroupc
# numbers/datautilities) to mavenLocal, mirroring how the gmscore stage
# publishes the microG play-services libs. gecko-localize_maven restricts the
# Gradle repo set to mavenLocal + plugins.gradle.org + google, so anything
# geckoview/build.gradle references as libs.cbor must exist in mavenLocal.
set -eu
M2="${M2_HOME:-$HOME/.m2}/repository"
CENTRAL="https://repo1.maven.org/maven2"

fetch() { # groupId path version artifact
  local g="$1" v="$2" a="$3"
  local d="$M2/$1/$3/$2"
  [ -f "$d/$3-$2.jar" ] && { echo "skip $1:$3:$2 (present)"; return; }
  mkdir -p "$d"
  curl -fsSL -o "$d/$3-$2.jar" "$CENTRAL/$1/$3/$2/$3-$2.jar"
  curl -fsSL -o "$d/$3-$2.pom" "$CENTRAL/$1/$3/$2/$3-$2.pom"
  echo "published $1:$3:$2"
}

# com.upokecenter:cbor:4.5.6 (transitive deps of the cbor pom, pinned to the
# versions the pom declares)
fetch com/upokecenter 4.5.6 cbor
fetch com/github/peteroupc 1.8.2 numbers
fetch com/github/peteroupc 1.1.0 datautilities

echo "cbor stack in mavenLocal:"
find "$M2/com/upokecenter" "$M2/com/github/peteroupc" -name "*.jar" 2>/dev/null || true
