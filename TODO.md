# TODO

- [x] Extract logging logic from `build-deps.sh` and place in `ci/libs/logging.sh`
  - [x] Use `logging::log_*` naming for logging functions
- [x] Handle rate limiting for GitHub API calls
- [x] Only run `apt install` once
- [] Properly detect previously released versions and don't build cleanly
- [] Add the ability to change the number of versions built
- [] Automatically generate the config based on the ebuild repo
- [] Automatically replace the `SRC_URI` in ebuilds with our release
- [] Fix the releaes note to not have the symbols '0%0A%'

## Future

For now this only supports go vendored tarballs, in the future if we want to add support
for rust vendored tarballs we'd have to tweak the config file is read.
