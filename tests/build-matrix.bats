#!/usr/bin/env bats

# Path to the script under test, resolved relative to this test file
SCRIPT="${BATS_TEST_DIRNAME}/../ci/build-matrix.sh"

setup() {
  TMPDIR="$(mktemp -d)"
  cd "$TMPDIR"

  # Create config, released tags, and ebuild registry files
  cat > cfg.json <<'EOF'
{
  "go": [
    {
      "name": "m",
      "repo": "acme/myrepo",
      "vcs": "https://example.com/myrepo.git"
    }
  ]
}
EOF

  echo "m-v1.0.0" > released.txt

  cat > registry.json <<'EOF'
[
  {"repo":"acme/myrepo","language":"go","versions":["1.1.0","1.2.0"]}
]
EOF

  # Wrapper script to stub get_release_tags without calling GitHub
  cat > run-matrix.sh <<'EOF'
#!/usr/bin/env bash
SCRIPT="$1"; shift
source "$SCRIPT"
get_release_tags() {
  echo v1.2.0
  echo v1.1.0
  echo v1.0.0
}
main "$@"
EOF
  chmod +x run-matrix.sh
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "vendored tags appear for multiple versions" {
  run bash run-matrix.sh "$SCRIPT" cfg.json released.txt registry.json

  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\"tag\":\"v1.1.0\"'
  echo "$output" | grep -q '\"tag\":\"v1.2.0\"'
  echo "$output" | grep -vq '\"tag\":\"v1.0.0\"'
}

