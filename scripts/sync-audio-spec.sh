#!/usr/bin/env bash
# Copies the audio spec fixtures of the Python Cue Media Engine into the AudioCoreTests resources.
#
#   scripts/sync-audio-spec.sh <path-to-python-repo>
#
# Reads the Python repo only. Refuses a Python working tree that is not clean (the fixtures are generated files, and a dirty tree can hold a
# half-finished regeneration). Writes Packages/Engine/Tests/AudioCoreTests/Fixtures/spec-<N>/ where N is
# the number on the first line of docs/AUDIO-SPEC.md ("Spec version: N (...)"). See docs/audio-conformance.md.
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <path-to-python-repo>" >&2
    exit 2
fi

src="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures_root="$root/Packages/Engine/Tests/AudioCoreTests/Fixtures"

spec="$src/docs/AUDIO-SPEC.md"
golden="$src/tests/golden-audio"
[ -f "$spec" ] || { echo "error: $spec not found (is this the Python repo?)" >&2; exit 1; }
[ -d "$golden/fixtures" ] || { echo "error: $golden/fixtures not found" >&2; exit 1; }

command -v git >/dev/null || { echo "error: git is required" >&2; exit 1; }
git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: $src is not a git working tree" >&2; exit 1; }
if [ -n "$(git -C "$src" status --porcelain --untracked-files=all)" ]; then
    echo "error: the Python tree at $src is not clean; commit or stash first so the stamp names exactly what was copied." >&2
    git -C "$src" status --short >&2
    exit 1
fi
commit="$(git -C "$src" rev-parse HEAD)"

first_line="$(head -n 1 "$spec" | tr -d '\r')"
version="$(printf '%s\n' "$first_line" | sed -n 's/^Spec version: \([0-9][0-9]*\).*/\1/p')"
if [ -z "$version" ]; then
    echo "error: first line of $spec is not 'Spec version: N ...': $first_line" >&2
    exit 1
fi

shopt -s nullglob
jsons=("$golden"/fixtures/*.json)
wavs=(crossfade.wav ducked.wav loop.wav trim_fade_out.wav)
[ ${#jsons[@]} -gt 0 ] || { echo "error: no fixtures in $golden/fixtures" >&2; exit 1; }
[ -f "$golden/renders/renders.json" ] || { echo "error: $golden/renders/renders.json not found" >&2; exit 1; }
for w in "${wavs[@]}"; do
    [ -f "$golden/renders/$w" ] || { echo "error: $golden/renders/$w not found" >&2; exit 1; }
done

# Every file must carry the same spec_version as the first line of the spec.
for f in "${jsons[@]}" "$golden/renders/renders.json"; do
    if ! grep -Eq "\"spec_version\": *$version[,}[:space:]]" "$f"; then
        echo "error: $f does not say spec_version $version (spec first line: $first_line)." >&2
        echo "       The Python repo is inconsistent; regenerate its fixtures." >&2
        exit 1
    fi
done

dest="$fixtures_root/spec-$version"
rm -rf "$dest"
mkdir -p "$dest/renders"
cp "${jsons[@]}" "$dest/"
cp "$golden/renders/renders.json" "$dest/renders/"
for w in "${wavs[@]}"; do cp "$golden/renders/$w" "$dest/renders/"; done
printf '%s\n' "$first_line" > "$dest/AUDIO-SPEC-LINE1.txt"
printf '%s\n' "$version" > "$dest/SPEC_VERSION"
# The stamp: which Python commit these fixtures were copied from. Read by SourceStampTests.
{
    echo "python_commit: $commit"
    echo "spec_version: $version"
} > "$dest/SOURCE.txt"

echo "synced spec $version -> ${dest#$root/}"
echo "  python commit $commit"
echo "  ${#jsons[@]} fixture files, renders.json, ${#wavs[@]} WAVs"

others=()
for d in "$fixtures_root"/spec-*; do
    [ -d "$d" ] && [ "$d" != "$dest" ] && others+=("$(basename "$d")")
done
if [ ${#others[@]} -gt 0 ]; then
    echo "note: older spec folder(s) still present: ${others[*]}"
    echo "      remove them (git rm -r) and update AudioSpec.pinnedVersion in the tests, or the suite will fail."
fi
