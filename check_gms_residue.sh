#!/usr/bin/env bash
# Guard: fail the build in ~2s if a GMS / microG import reappears in the
# mobile android sources, instead of 2.5h later at a gradle compile stage.
#
# Scans IMPORT lines only (package-name strings in telemetry allowlists and
# KDoc mentions are not imports and are out of scope). Any import not on the
# allowlist fails the build with the offending lines printed.
#
# Allowlist — every entry is GMS-RUNTIME-free (module builds and runs without
# GMS; the gms.* classes it imports are AOSP/framework stubs or the module is
# excluded from the build graph entirely):
#   push-firebase — com.google.android.gms.common.{ConnectionResult,
#                   GoogleApiAvailability}: checks whether GMS is present at
#                   runtime; the classes themselves are AOSP stubs. The module
#                   builds GMS-free (proven: every green run to date).
#   lib-integrity-googleplay — play-integrity module, EXCLUDED from the AC
#                   build graph via .buildconfig.yml; never compiled here.
# Everything else — fenix app, geckoview, focus-android, all other AC modules
# and their test sources — must stay GMS-free. If an import is legitimately
# needed, extend this allowlist with a comment explaining why it is
# GMS-runtime-free.
set -euo pipefail
# $1 = root of the patched mozilla source tree (contains mobile/android/).
# Called from the srclib tree, not the fennecbuild repo.
TREE="${1:-.}"
cd "$TREE"
[ -d mobile/android ] || { echo "gms-residue guard: $TREE has no mobile/android/ — wrong tree?"; exit 1; }

ALLOW='^mobile/android/android-components/components/lib/(push-firebase|integrity-googleplay)/'
# focus-android is a separate app NOT built by this pipeline (fenix's
# settings.gradle includes no focus module) — its GMS imports don't affect
# the build. Excluded explicitly so the exclusion is visible if focus is
# ever added to the build graph.
EXCLUDE='^mobile/android/focus-android/'

hits=$(grep -rn --include="*.kt" --include="*.java" \
  -E '^\s*import (com\.google\.android\.gms|org\.microg|com\.google\.android\.play|com\.google\.play)\.' \
  mobile/android/ 2>/dev/null || true)

bad=$(printf '%s\n' "$hits" | grep -vE "$ALLOW" | grep -vE "$EXCLUDE" || true)

if [ -n "$bad" ]; then
  echo "GMS-RESIDUE GUARD: unapproved GMS/microG import in mobile/android sources:"
  printf '%s\n' "$bad"
  echo
  echo "This breaks the GMS-free build (no microG/GMS artifacts on the classpath)."
  echo "If the import is legitimately needed, extend the allowlist in"
  echo "check_gms_residue.sh with a comment explaining why it is GMS-safe."
  exit 1
fi
n=$(printf '%s\n' "$hits" | grep -c . || true)
echo "gms-residue guard: clean ($n allowed imports, 0 others)"
