#!/usr/bin/env bats

# Path to the script under test, resolved relative to this test file
SCRIPT="${BATS_TEST_DIRNAME}/../ci/build-matrix.sh"

setup() {
  TMPDIR="$(mktemp -d)"
  cd "$TMPDIR"

  # Initialize a dummy repo with two tags
  git init repo
  cd repo
  echo hi > a; git add a; git commit -m "init"
  git tag v1.0; git tag v1.1

  # Create config and released-tags files
  cd ..
  printf '[{"name":"m","repo":"r","vcs":"%s/repo"}]' "$PWD" > cfg.json
  printf "v1.0\n" > released.txt
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "only unreleased tag shows up" {
  # Run the build-matrix script
  run bash "$SCRIPT" cfg.json released.txt

  # It should exit successfully
  [ "$status" -eq 0 ]

  # Output should include v1.1 but not v1.0
  echo "$output" | grep -q '"tag":"v1.1"'
  echo "$output" | grep -vq '"tag":"v1.0"'
}
