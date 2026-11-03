<!-- CI does not build the app yet: GitHub's runners ship Xcode 26 and this
project needs Xcode 27. Run the checks below locally and paste the results. -->

## What changes

## Checks run locally (Xcode 27+)

- [ ] `make test-core` — paste the last line (`Test run with N tests ... passed`)
- [ ] `make build-device`
- [ ] `bash tests/mac/test-sync.sh` (if `mac/` changed)
- [ ] Tested on a real iPhone (model, iOS version), or say what you could not test
