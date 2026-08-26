fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload OshiReader Local metadata to App Store Connect

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

Download OshiReader Local metadata from App Store Connect

### ios paid_acceptance_archive

```sh
[bundle exec] fastlane ios paid_acceptance_archive
```

Build a signed paid-catalog acceptance IPA without enabling the repository default catalog

### ios paid_acceptance_beta

```sh
[bundle exec] fastlane ios paid_acceptance_beta
```

Build and upload the paid-catalog acceptance candidate to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
