# TODO

- Extract logging logic from `build-deps.sh` and place in `ci/libs/logging.sh`
  - Use `logging::log_*` naming for logging functions
- Handle rate limiting for github API calls
- Only run `apt install` once

## Future

For now this only supports go vendored tarballs, in the future if we want to add support
for rust vendored tarballs we'd have to tweak the config file is read.
