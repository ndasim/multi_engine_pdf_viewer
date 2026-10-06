#!/usr/bin/env bash
# Vendors a pdfjs-dist release (legacy build) into assets/pdfjs.
# Usage: tool/update_pdfjs.sh 4.1.392
set -euo pipefail

version="${1:?usage: tool/update_pdfjs.sh <pdfjs-dist version>}"
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
target="$package_dir/assets/pdfjs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

url="https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-$version.tgz"
curl -fsSL "$url" -o "$work/pdfjs.tgz"
tar -xzf "$work/pdfjs.tgz" -C "$work"
src="$work/package"

rm -rf "$target"
mkdir -p "$target/build" "$target/web/images" "$target/cmaps" "$target/standard_fonts"
cp "$src/legacy/build/pdf.min.mjs" "$src/legacy/build/pdf.worker.min.mjs" "$target/build/"
cp "$src/legacy/web/pdf_viewer.mjs" "$src/legacy/web/pdf_viewer.css" "$target/web/"
cp "$src"/legacy/web/images/annotation-*.svg "$target/web/images/"
cp "$src"/cmaps/* "$target/cmaps/"
cp "$src"/standard_fonts/* "$target/standard_fonts/"
cp "$src/LICENSE" "$target/LICENSE"

sha="$(shasum -a 256 "$work/pdfjs.tgz" | cut -d' ' -f1)"
printf 'pdfjs-dist %s (legacy build)\nsource: %s\nsha256: %s\n' "$version" "$url" "$sha" > "$target/VERSION"

echo "Vendored pdfjs-dist $version. Check the build targets and review the diff before committing."
