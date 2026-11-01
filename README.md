# KVXR — Kaiwne's Void Extended Repository

Custom binary & source package repository for **Void Linux** (`x86_64-glibc`).

## Quick Start

Add the repository and sync package index:

```shell
printf "repository=https://github.com/kaiwne/KVXR/releases/download/x86_64-glibc\n" | sudo tee /etc/xbps.d/kvxr.conf
sudo xbps-install -S
```

## Available Packages

| Package | Description | Upstream | Auto-Update |
| :--- | :--- | :--- | :---: |
| [`brave-origin`](srcpkgs/brave-origin/template) | Fast, private and secure web browser with ad blocker | [brave/brave-browser](https://github.com/brave/brave-browser) | ✅ |
| [`cordial`](srcpkgs/cordial/template) | Runs Roblox's official Android build natively on Linux | [luohoa97/cordial](https://github.com/luohoa97/cordial) | ✅ |
| [`fcitx5-lotus`](srcpkgs/fcitx5-lotus/template) | Fcitx5 Lotus — Vietnamese IME | [LotusInputMethod/fcitx5-lotus](https://github.com/LotusInputMethod/fcitx5-lotus) | ✅ |
| [`fcitx5-lotus-settings`](srcpkgs/fcitx5-lotus/template) | Fcitx5 Lotus — Settings GUI | [LotusInputMethod/fcitx5-lotus](https://github.com/LotusInputMethod/fcitx5-lotus) | ✅ |
| [`fcitx5-ngosen`](srcpkgs/fcitx5-ngosen/template) | Ngó Sen, a Vietnamese input method for fcitx5 | [ngosen/ngosen](https://github.com/ngosen/ngosen) | ✅ |
| [`helium-browser`](srcpkgs/helium-browser/template) | Fast, private and secure web browser with ad blocker | [imputnet/helium-linux](https://github.com/imputnet/helium-linux) | ✅ |
| [`mangowc`](srcpkgs/mangowc/template) | Dwl-based Wayland compositor using scenefx | [mangowm/mango](https://github.com/mangowm/mango) | ✅ |
| [`pineconemc`](srcpkgs/pineconemc/template) | Prism Launcher fork with Ely.by account support | [ElyPrismLauncher/Launcher](https://github.com/ElyPrismLauncher/Launcher) | ✅ |
| [`scenefx`](srcpkgs/scenefx/template) | Drop-in replacement for the wlroots scene API | [wlrfx/scenefx](https://github.com/wlrfx/scenefx) | ✅ |
| [`scenefx-devel`](srcpkgs/scenefx/template) | Drop-in replacement for the wlroots scene API (devel) | [wlrfx/scenefx](https://github.com/wlrfx/scenefx) | ✅ |
| [`ttf-apple-emoji`](srcpkgs/ttf-apple-emoji/template) | Apple Color Emoji typeface | [samuelngs/apple-emoji-ttf](https://github.com/samuelngs/apple-emoji-ttf) | ➖ |
| [`ttf-google-sans`](srcpkgs/ttf-google-sans/template) | Google Sans Font | [google/fonts](https://github.com/google/fonts) | ➖ |
| [`ttf-google-sans-flex`](srcpkgs/ttf-google-sans-flex/template) | Google Sans Flex Font | [google/fonts](https://github.com/google/fonts) | ➖ |
| [`ttf-jetbrains-mono`](srcpkgs/ttf-jetbrains-mono/template) | JetBrains Mono typeface | [jetbrains/jetbrainsmono](https://github.com/jetbrains/jetbrainsmono) | ✅ |
| [`vscode`](srcpkgs/vscode/template) | Visual Studio Code — Code Editing. Redefined | [code.visualstudio.com](https://code.visualstudio.com/) | ✅ |

## Repository Structure

```text
KVXR/
├── .github/workflows/
│   ├── build.yml      # Build, sign & publish packages to GitHub Releases
│   └── update.yml     # Scheduled auto-updater for all package templates
├── common/
│   └── shlibs         # Custom shared library mappings for xbps-src
├── scripts/
│   └── update.sh      # Universal package template updater
└── srcpkgs/           # Standard xbps-src package templates
```

## Local Usage

```shell
# Check for upstream updates without modifying templates
./scripts/update.sh --check

# Update all package templates and recalculate SHA256 checksums
./scripts/update.sh

# Update specific package(s)
./scripts/update.sh pineconemc fcitx5-ngosen vscode
```
