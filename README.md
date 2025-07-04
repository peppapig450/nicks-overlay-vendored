# Vendored distfiles for Nick's Overlay

This repo provides pipelines for automatically vendoring distfiles required for some packages in [Nick's Overlay](https://github.com/peppapig450/nicks_repo)

## Configuration

Dependencies to vendor are defined in [vendor_manifest.json](config/vendor_manifest.json).  Each key in the manifest corresponds to a language (e.g. `go`, `rust`) and lists the repositories to vendor.  Entries may optionally specify a `subdir` to vendor from within the repository.  Example:

```json
{
  "go": [
    { "name": "glow", "repo": "charmbracelet/glow", "vcs": "https://github.com/charmbracelet/glow.git", "subdir": "" }
  ],
  "rust": [
    { "name": "lutgen-rs", "repo": "ozwaldorf/lutgen-rs", "vcs": "https://github.com/ozwaldorf/lutgen-rs", "subdir": "" }
  ]
}
```

The optional `subdir` path is relative to the repository root and tells the
build scripts where to run vendoring commands. Leave it empty when dependencies
are fetched from the repository root.

## Building tarballs

Language specific scripts in `ci/` can be used to create dependency tarballs locally:

```bash
jq -n '{"name":"glow","repo":"charmbracelet/glow","vcs":"https://github.com/charmbracelet/glow.git","tag":"v1.4.1","subdir":""}' \
  | bash ci/build-go-deps.sh
```

Similar scripts exist for Rust (`ci/build-rust-deps.sh`). Each script outputs the path to the produced tarball.

The GitHub Actions workflow [`build-dep-tarballs.yml`](.github/workflows/build-dep-tarballs.yml) runs these scripts automatically for new tags discovered in upstream repositories.
