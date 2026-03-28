# baobab-macos-builder

Builds `Baobab.app` for macOS from upstream Baobab sources.

## Why this project exists

Baobab is useful on macOS, but running the Homebrew-installed binary directly has several practical drawbacks:

- it does not show up as a normal app that can be launched from Spotlight
- launching it from a terminal keeps the process tied to that shell and pushes logs/errors into the terminal session
- macOS privacy permissions are easier to manage for an app bundle than for a process started from a terminal with inherited security context

This repository exists to build a proper macOS app bundle that can be copied into `/Applications` and used like a normal app.

## Requirements

Install the build tools and icon packager:

```bash
brew install bash meson ninja vala desktop-file-utils itstool librsvg makeicns
```

Install the runtime libraries and assets Baobab links against:

```bash
brew install gettext glib gtk4 libadwaita pango cairo graphene gdk-pixbuf adwaita-icon-theme hicolor-icon-theme
```

The build also uses macOS-provided tools such as `codesign`, `iconutil`, `install_name_tool`, `otool`, `plutil`, and `sips`.

`gsettings` must also be available at build-validation time. It is provided by Homebrew `glib`.

## What it does

- downloads a pinned Baobab release tarball by default
- verifies the source archive with `sha256`
- builds with Meson in `release` mode by default, or `debugoptimized` with `--debug`
- stages Baobab and Baobab-owned resources into `out/Baobab.app`
- renders the upstream Baobab SVG into a macOS `.icns` app icon
- rewrites non-system dylib references on the Baobab binary to `@rpath`
- adds runtime search paths based on the detected host libraries
- validates runtime linkage and required GTK/GSettings schemas in a Finder-like clean environment
- ad-hoc signs the final app bundle
- writes launcher stdout/stderr to `~/Library/Logs/Baobab/baobab.log`

The generated app is intended to be relocatable on the same host machine where it was built.

## Usage

```bash
./build-baobab-app.sh
./build-baobab-app.sh --debug
```

Common overrides:

```bash
BAOBAB_DEBUG=1 ./build-baobab-app.sh
./build-baobab-app.sh --version 50.0 --sha256 <sha256>
./build-baobab-app.sh --source-url <url>
./build-baobab-app.sh --source-tarball <path>
./build-baobab-app.sh --source-dir <path>
./build-baobab-app.sh --output-dir <path>
./build-baobab-app.sh --brew-prefix "$(brew --prefix)"
./build-baobab-app.sh --sign-identity -
```

To force a specific Bash interpreter:

```bash
BAOBAB_BASH_BIN=/path/to/bash ./build-baobab-app.sh
```

## Release config

Edit `config/baobab-release.conf` to update:

- `BAOBAB_VERSION`
- `BAOBAB_SHA256`
- `BAOBAB_SOURCE_URL`
- `BAOBAB_BUNDLE_ID`
- `BAOBAB_APP_NAME`
- `BAOBAB_SIGN_IDENTITY`

## Outputs

- app bundle: `out/Baobab.app`
- downloads: `out/downloads/`
- build worktree: `out/work/`
- launcher log: `~/Library/Logs/Baobab/baobab.log`

## Notes

- The launcher sets `XDG_DATA_DIRS` to the app bundle's `Resources/share`, then the detected Homebrew `share`, then any inherited `XDG_DATA_DIRS`.
- The app icon is generated from Baobab's upstream SVG icon during the build and stored as `Contents/Resources/Baobab.icns`.
- Runtime validation checks the app-owned executable for unresolved `@rpath`, stale build paths, unexpected absolute library references, and missing GTK file-chooser schemas in a clean launch environment.
- The scripts can use `BAOBAB_BASH_BIN`, otherwise they detect Bash from Homebrew when available and fall back to `bash` on `PATH`.
