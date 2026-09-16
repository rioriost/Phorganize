#!/bin/sh
set -eu

threshold="${1:-80}"
awk -v threshold="$threshold" 'BEGIN {
  if (threshold !~ /^[0-9]+([.][0-9]+)?$/ || threshold + 0 > 100) {
    print "Coverage threshold must be a number between 0 and 100." > "/dev/stderr"
    exit 1
  }
}'
swift test --enable-code-coverage --quiet

bin_path="$(swift build --show-bin-path)"
profile="$bin_path/codecov/default.profdata"
set --
for bundle in "$bin_path"/*.xctest; do
  binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
  [ -f "$binary" ] || continue
  if [ "$#" -eq 0 ]; then
    set -- "$binary"
  else
    set -- "$@" -object "$binary"
  fi
done

if [ "$#" -eq 0 ]; then
  printf 'No test executables found in %s.\n' "$bin_path" >&2
  exit 1
fi

report="$(xcrun llvm-cov report "$@" \
  -instr-profile "$profile" \
  -ignore-filename-regex='Tests|PhorganizeApp|resource_bundle_accessor|runner.swift')"

printf '%s\n' "$report"

coverage="$(printf '%s\n' "$report" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
if [ -z "$coverage" ]; then
  printf '%s\n' "Could not read line coverage from llvm-cov output." >&2
  exit 1
fi
awk -v actual="$coverage" -v threshold="$threshold" '
  BEGIN {
    if (actual !~ /^[0-9]+([.][0-9]+)?$/ || actual + 0 > 100) {
      print "Invalid line coverage in llvm-cov output." > "/dev/stderr"
      exit 1
    }
    if (actual + 0 < threshold + 0) {
      printf("Coverage %.2f%% is below the %.2f%% target.\n", actual, threshold) > "/dev/stderr"
      exit 1
    }
  }
'
