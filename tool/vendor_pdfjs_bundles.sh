#!/usr/bin/env bash
# Vendors the three PDF.js bundles the viewer picks between:
#
#   legacy  - an older major, transpiled. The only one whose CSS avoids
#             `light-dark()`, and the only one that parses below iOS 16.4.
#   compat  - the newest major, transpiled and polyfilled (pdfjs-dist/legacy).
#             Runs from iOS 16.4 up.
#   current - the newest major, untranspiled. Needs iOS 26 or newer.
#
# compat and current are the same PDF.js version on purpose: every device that
# can run the newest PDF.js at all should get it, and only the build differs.
#
# Usage: tool/vendor_pdfjs_bundles.sh [legacy-version] [current-version]
set -euo pipefail

legacy_version="${1:-4.1.392}"
current_version="${2:-6.3.289}"
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
target="$package_dir/assets/pdfjs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

vendor_bundle() {
  local name="$1"
  local version="$2"
  local source_root="$3"
  local archive="$work/$name.tgz"
  local extract="$work/$name"
  local url="https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-$version.tgz"

  curl -fsSL "$url" -o "$archive"
  mkdir -p "$extract"
  tar -xzf "$archive" -C "$extract"

  local source="$extract/package/$source_root"
  local destination="$target/$name"
  mkdir -p "$destination/build" "$destination/web/images"
  # Only the minified entry points are ever served; shipping the unminified
  # twins would add megabytes to the app for nothing.
  cp "$source/build/pdf.min.mjs" "$source/build/pdf.worker.min.mjs" "$destination/build/"
  cp "$source/web/pdf_viewer.mjs" "$source/web/pdf_viewer.css" "$destination/web/"
  cp "$source"/web/images/annotation-*.svg "$destination/web/images/"

  printf '%s %s\nsource: %s\nsha256: %s\n' \
    "$name" "$version" "$url" "$(shasum -a 256 "$archive" | cut -d' ' -f1)" >> "$target/VERSION"
}

rm -rf "$target"
mkdir -p "$target/cmaps" "$target/standard_fonts"
: > "$target/VERSION"
vendor_bundle legacy "$legacy_version" legacy
vendor_bundle compat "$current_version" legacy
vendor_bundle current "$current_version" .

current_source="$work/current/package"
cp "$current_source"/cmaps/* "$target/cmaps/"
cp "$current_source"/standard_fonts/* "$target/standard_fonts/"
cp "$current_source/LICENSE" "$target/LICENSE"

echo "Vendored legacy $legacy_version and current $current_version. Review the diff before committing."
