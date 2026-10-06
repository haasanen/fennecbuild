#!/bin/bash
#
#    Fennec build scripts
#    Copyright (C) 2020-2024  Matías Zúñiga, Andrew Nayenko, Tavi
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 versionName versionCode" >&1
    exit 1
fi

# shellcheck source=paths.sh
source "$(dirname "$0")/paths.sh"

function localize_maven {
    # Replace custom Maven repositories with mavenLocal()
    find ./* -name '*.gradle' -type f -print0 | xargs -0 \
        sed -n -i \
            -e '/maven {/{:loop;N;/}$/!b loop;/plugins.gradle.org/!s/maven .*/mavenLocal()/};p'
    # Make gradlew scripts call our Gradle wrapper
    find ./* -name gradlew -type f | while read -r gradlew; do
        echo -e '#!/bin/sh\ngradle "$@"' > "$gradlew"
        chmod 755 "$gradlew"
    done
}

function apply_patch {
    echo "Apply $1"
    patch -p1 --no-backup-if-mismatch --quiet < "$1"
}

# Set up Rust
rustup default 1.95.0

#
# Fenix
#

pushd "$fenix"

# Set up the app ID, version name and version code
sed -i \
    -e 's|\.firefox|.fennec_fdroid|' \
    -e "s/Config.releaseVersionName(project)/'$1'/" \
    -e "s/Config.generateFennecVersionCode(abi)/$2/" \
    app/build.gradle
sed -i \
    -e '/android:targetPackage/s/firefox/fennec_fdroid/' \
    app/src/release/res/xml/shortcuts.xml

# Disable crash reporting
sed -i -e '/CRASH_REPORTING/s/true/false/' app/build.gradle

# Disable MetricController
sed -i -e '/TELEMETRY/s/true/false/' app/build.gradle

# Let it be Fennec
sed -i -e 's/Firefox Daylight/Fennec/; s/Firefox/Fennec/g' \
    app/src/*/res/values*/*strings.xml

# Fenix uses reflection to create a instance of profile based on the text of
# the label, see
# app/src/main/java/org/mozilla/fenix/perf/ProfilerStartDialogFragment.kt#185
sed -i \
    -e 's/ProfilerSettings.Firefox/ProfilerSettings.Fennec/' \
    app/src/main/java/org/mozilla/fenix/perf/ProfilerStartDialogFragment.kt
sed -i \
    -e '/Firefox(.*, .*)/s/Firefox/Fennec/' \
    -e 's/firefox_threads/fennec_threads/' \
    -e 's/firefox_features/fennec_features/' \
    app/src/main/java/org/mozilla/fenix/perf/ProfilerUtils.kt
# The profiler unit test (added upstream after this fork) still references
# ProfilerSettings.Firefox; apply the same rename so it compiles.
sed -i \
    -e 's/ProfilerSettings\.Firefox/ProfilerSettings.Fennec/g' \
    app/src/test/java/org/mozilla/fenix/perf/ProfilerViewModelTest.kt
# The unified-push switch moves AutoPushSubscription from
# mozilla.components.feature.push to org.ironfoxoss.unifiedpush (same
# constructor shape); follow it in the webpush unit test.
sed -i \
    -e 's/import mozilla\.components\.feature\.push\.AutoPushSubscription/import org.ironfoxoss.unifiedpush.AutoPushSubscription/' \
    app/src/test/java/org/mozilla/fenix/push/WebPushEngineIntegrationTest.kt

# Replace proprietary artwork
sed -i -e 's|@drawable/animated_splash_screen<|@drawable/splash_screen<|' \
    app/src/main/res/values-v*/styles.xml
find "$patches/fenix-overlay" -type f | while read -r src; do
    dst=app/src/release/${src#"$patches/fenix-overlay/"}
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
done

# Enable about:config
sed -i \
    -e 's/aboutConfigEnabled(.*)/aboutConfigEnabled(true)/' \
    app/src/*/java/org/mozilla/fenix/*/GeckoProvider.kt

# Disable remote improvements by default
sed -i \
    -e '/android:defaultValue=/s/"true"/"false"/' \
    app/src/main/res/xml/remote_improvements_preferences.xml

# Add wallpaper URL
echo 'https://gitlab.com/relan/fennecmedia/-/raw/master/wallpapers/android' > .wallpaper_url

# Set up target parameters
case $(echo "$2" | cut -c 6) in
    0)
        abi=armeabi-v7a
        target=arm-linux-androideabi
        echo "ARM" > "$llvm/targets_to_build"
        rusttarget=arm
        rustup target add thumbv7neon-linux-androideabi
        rustup target add armv7-linux-androideabi
        ;;
    1)
        abi=x86_64
        target=x86_64-linux-android
        echo "X86" > "$llvm/targets_to_build"
        rusttarget=x86_64
        rustup target add x86_64-linux-android
        ;;
    2)
        abi=arm64-v8a
        target=aarch64-linux-android
        echo "AArch64" > "$llvm/targets_to_build"
        rusttarget=arm64
        rustup target add aarch64-linux-android
        ;;
    *)
        echo "Unknown target code in $2." >&2
        exit 1
    ;;
esac
sed -i -e "s/include \".*\"/include \"$abi\"/" app/build.gradle

# Disable FUS Service or we'll get errors like:
# Exception while loading configuration for :app: Could not load the value of field `__buildFusService__` of task `:app:compileFenixReleaseKotlin` of type `org.jetbrains.kotlin.gradle.tasks.KotlinCompile`.
echo "kotlin.internal.collectFUSMetrics=false" >> local.properties

popd

#
# Glean
#

pushd "$glean"
echo "rust.targets=linux-x86-64,$rusttarget" >> local.properties
localize_maven
popd

#
# Glean for Application Services
#

pushd "$glean_as"
echo "rust.targets=linux-x86-64,$rusttarget" >> local.properties
localize_maven
popd

#
# Android Components
#

pushd "$android_components"
find "$patches/a-c-overlay" -type f | while read -r src; do
    cp "$src" "${src#"$patches/a-c-overlay/"}"
done
# Add the added search engines as `general` engines
sed -i \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "brave",' \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "ddghtml",' \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "ddglite",' \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "metager",' \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "mojeek",' \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "qwantlite",' \
    -e '/GENERAL_SEARCH_ENGINE_IDS = setOf/a\    "startpage",' \
    components/feature/search/src/main/java/mozilla/components/feature/search/storage/SearchEngineReader.kt
popd

#
# UnifiedPush Android Component
#

pushd "$unifiedpush_ac"
localize_maven
# Set A-C version. $1 is the APP versionName and may carry the fork build
# suffix (157.0.0-h<N>); the A-C dependency version must stay the engine base
# (157.0) — that is what the 'ac'/'ac_fetch150' stages publish to ~/.m2.
# Stripping the suffix first keeps ${AC_BASE%.0} == 157.0 for both the plain
# 157.0.0 name and any -h<N> variant.
AC_BASE=${1%%-h[0-9]*}
echo "mozilla.version=${AC_BASE%.0}" >> local.properties
# Set A-S version. Must match what the A-S stage publishes to ~/.m2, which
# is the VERSION of the pinned application-services tag (version.txt:
# v155.0 -> 155.0, v157.0.1 -> 157.0.1). Read it from the checkout so a
# patch-level pin (x.y.z) can never desync from this line again.
AS_VERSION=$(cat "$application_services/version.txt")
echo "as.version=$AS_VERSION" >> local.properties
popd

#
# Application Services
#

pushd "$application_services"
rm -vrf components/remote_settings/dumps/*/attachments/search-config-icons/*
find "$patches/a-s-overlay" -type f | while read -r src; do
    cp "$src" "${src#"$patches/a-s-overlay/"}"
done
# Remove Mozilla repositories substitution and explicitly add the required ones
apply_patch "$patches/a-s-localize_maven.patch"
# Configure default search engines
apply_patch "$patches/a-s-configure-default-search-engines.patch"
# Select only the required architectures
echo "rust.targets=linux-x86-64,$rusttarget" >> local.properties
popd

#
# WASI SDK
#

pushd "$wasi"
# 157 replaced Mozilla's wasi-sdk.patch with two trunk-only patches
# (wasi-sdk-compat / wasi-sdk-no-llvm-patches) that target the wasi-sdk-23+
# cmake build; we pin wasi-sdk-20, so carry the 155-era patch in-repo.
apply_patch "$patches/wasi-sdk.patch"
popd

#
# GeckoView
#

pushd "$mozilla_release"

# Remove unneeded dependencies
apply_patch "$patches/gecko-dependencies.patch"

# Remove Mozilla repositories substitution and explicitly add the required ones
apply_patch "$patches/gecko-localize_maven.patch"

# Replace GMS with the microG client library (upstream patches), then move to
# in-process FIDO2/WebAuthn security keys (CTAP2 over USB/NFC — no FIDO
# service on the device) and drop the microG/GMS residue.
apply_patch "$patches/m-c-liberate.patch"
apply_patch "$patches/gecko-liberate.patch"
# In-process FIDO2/WebAuthn security keys: CTAP2 over USB/NFC, no FIDO service
# (works on GMS-free devices such as GrapheneOS). Replaces the
# play-services-fido client binding above; the CBOR codec (com.upokecenter:cbor)
# is published to mavenLocal by the 'cbor' phase-3 stage.
apply_patch "$patches/gecko-security-key.patch"

# Prevent websites from being able to detect that a user is using Fennec F-Droid
## (based on the presence of resources used by `about:crashes`)
apply_patch "$patches/gecko-prevent-fingerprinting-via-crash-resources.patch"

# Work-around upstream bug to fix compilation with WASI SDK 20, see
# https://bugzilla.mozilla.org/show_bug.cgi?id=1994063
apply_patch "$patches/gecko-unbreak-wasi-sdk-20-clang.patch"

# Keep the Rust build inside the 15 GiB build machine: drop fat LTO and the
# codegen-units=1 release setting (a single geckoservo codegen is a ~10 GiB
# rustc job with both on). Final binary is slower/bigger — restore on a
# bigger machine.
apply_patch "$patches/gecko-rust-small-memory.patch"

# Add "marionette.hide" option into about:config
apply_patch "$patches/gecko-option-to-hide-marionette.patch"

# Add UnifiedPush support. The patches are fork-owned (regenerated for the
# 157 tree); the UnifiedPushAC clone is still used for its maven-localize
# and version wiring, but its 1.0.6-era patch files no longer apply to 157.
apply_patch "$patches/a-c-unifiedpush.patch"
apply_patch "$patches/fenix-unifiedpush.patch"

# Patch the use of proprietary and tracking libraries
apply_patch "$patches/a-c-liberate.patch"
apply_patch "$patches/fenix-liberate.patch"
# Full GMS/microG removal: the CTAP2 port above replaced the FIDO service
# binding, so drop the last org.microg consumers (Adjust ads-id, the
# integrity stub's play-services-tasks), the inert GMS oss-licenses plugin,
# and take the integrity module out of the AC build graph (nothing in this
# build references it — a-c-liberate removed the code seam, fenix-liberate
# the app-level dependency).
apply_patch "$patches/gms-free.patch"

# Disable search engines configuration fetching from a Mozilla server
apply_patch "$patches/fenix-disable-remote-search-configuration.patch"
sed -i 's|https://firefox.settings.services.allizom.org/v1/buckets/main/collections/search-config/records||g' toolkit/components/search/SearchUtils.sys.mjs
sed -i 's|https://firefox.settings.services.allizom.org/v1/buckets/main-preview/collections/search-config/records||g' toolkit/components/search/SearchUtils.sys.mjs
sed -i 's|https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/search-config/records||g' toolkit/components/search/SearchUtils.sys.mjs
sed -i 's|https://firefox.settings.services.mozilla.com/v1/buckets/main-preview/collections/search-config/records||g' toolkit/components/search/SearchUtils.sys.mjs

# Remove the use of RemoteSettingsCrashPull, the part of the crash reporter
apply_patch "$patches/fenix-disable-crashpull.patch"

# Remove "Sent from Firefox" reference on sharing
apply_patch "$patches/fenix-disable-sent-from-fx.patch"

# Add "Enable UnifiedPush" and "Use UnifiedPush" settings
apply_patch "$patches/fenix-use-unifiedpush.patch"

# Adapt the upstream fenix unit tests to the fork's behavior so the full
# suite (gated by fingerprint in CI) passes: rename the "Firefox" display
# strings to "Fennec" (the *strings.xml rename above changes what the tests
# read at runtime) and update the defaults for the features this fork
# disables (telemetry, experimentation, crash reporting, Pocket
# recommendations). Touches test files only.
apply_patch "$patches/fenix-adapt-unit-tests.patch"

# There are a lot of "No cast needed" warnings in the generated code
sed -i -e 's/allWarningsAsErrors, true/allWarningsAsErrors, false/' mobile/android/gradle/plugins/conventions/src/main/java/org/mozilla/conventions/ProjectPlugin.kt

# Fail on use of prebuilt binary
sed -i 's|https://|hxxps://|' mobile/android/gradle/plugins/nimbus-gradle-plugin/src/main/kotlin/org/mozilla/appservices/tooling/nimbus/NimbusGradlePlugin.kt

# Make Nimbus Gradle Plugin use obj/dist/host/bin/nimbus-fml which we copy
# there manually from A-S. Otherwise Nimbus Gradle Plugin tries to download
# nimbus-fml from Mozilla.
sed -i 's/mozconfigSubsts?.get("MOZ_APPSERVICES_IN_TREE").isTruthy()/true/' mobile/android/gradle/plugins/nimbus-gradle-plugin/src/main/kotlin/org/mozilla/appservices/tooling/nimbus/NimbusGradlePlugin.kt

# Build the release artifacts
apply_patch "$patches/gecko-release-artifacts.patch"

# Remove unneeded GeckoView Gradle tasks
apply_patch "$patches/gecko-remove-irrelevant-gradle-tasks.patch"

# Residual 157-rebase hunks that no other patch carries: the
# org.ironfoxoss.unifiedpush dependency in feature/push/build.gradle and the
# enableUnifiedPush/useUnifiedPush Settings.kt properties. Last in the chain
# (same position as the verified e2e157 order; Settings.kt hunks must apply
# after fenix-liberate + fenix-disable-sent-from-fx).
apply_patch "$patches/fork-rebase-157-hunks.patch"

# Fail in ~2s if a GMS/microG import reappeared in the mobile android
# sources (the failure class that cost runs #1-#7 2.5h each to surface at
# a gradle compile stage). Checks the fully patched tree.
bash "$patches/check_gms_residue.sh" "$mozilla_release"

# Hack the timeout for
# geckoview:generateJNIWrappersForGeneratedWithGeckoBinariesDebug
sed -i \
    -e 's/max_wait_seconds=600/max_wait_seconds=1800/' \
    mobile/android/gradle.py

# Patch the LLVM source code
# Search clang- in https://android.googlesource.com/platform/ndk/+/refs/tags/ndk-r28b/ndk/toolchains.py
LLVM_SVN='530567'
python3 "$toolchain_utils/llvm_tools/patch_manager.py" \
    --svn_version "$LLVM_SVN" \
    --patch_metadata_file "$llvm_android/patches/PATCHES.json" \
    --src_path "$llvm"

# Fail on use of prebuilt binary
sed -i 's|https://github.com|hxxps://github.com|' python/mozboot/mozboot/android.py

# Make the build system think we installed the emulator and an AVD
mkdir -p "$ANDROID_HOME/emulator"
mkdir -p "$HOME/.mozbuild/android-device/avd"

# Use terser from Debian
sed -i \
    -e 's|terser_path = terser_dir / ".*"|terser_path = Path("/usr/bin/terser")|' \
    python/mozbuild/mozpack/files.py

# Configure
cat << EOF > mozconfig
ac_add_options --disable-crashreporter
ac_add_options --disable-debug
ac_add_options --disable-tests
ac_add_options --disable-updater
ac_add_options --enable-application=mobile/android
ac_add_options --enable-release
ac_add_options --enable-update-channel=release
ac_add_options --target=$target
ac_add_options --with-android-ndk="$ANDROID_NDK"
ac_add_options --with-android-sdk="$ANDROID_SDK"
ac_add_options --with-libclang-path="$llvm/out/lib"
ac_add_options --with-java-bin-path="/usr/bin"
ac_add_options --with-gradle=$(command -v gradle)
ac_add_options --with-wasi-sysroot="$wasi/build/install/wasi/share/wasi-sysroot"
ac_add_options CC="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
ac_add_options CXX="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
ac_add_options STRIP="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
ac_add_options WASM_CC="$wasi/build/install/wasi/bin/clang"
ac_add_options WASM_CXX="$wasi/build/install/wasi/bin/clang++"
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/obj
EOF

# Disable Gecko Media Plugins and casting
sed -i -e '/gmp-provider/d; /casting.enabled/d' mobile/android/app/geckoview-prefs.js
cat << EOF >> mobile/android/app/geckoview-prefs.js

// Disable Encrypted Media Extensions
pref("media.eme.enabled", false);

// Disable Gecko Media Plugins
pref("media.gmp-provider.enabled", false);

// Avoid openh264 being downloaded
pref("media.gmp-manager.url.override", "data:text/plain,");

// Disable openh264 if it is already downloaded
pref("media.gmp-gmpopenh264.enabled", false);

// Disable RemoteSettingsCrashPull
pref("browser.crashReports.onDemand", false, locked);
pref("browser.crashReports.requestedNeverShowAgain", true, locked);
EOF

popd
