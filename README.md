# Plex Screensaver for macOS — V1.0 Metal

A GPU-accelerated macOS screen saver displaying Plex Media Server status with a cinematic animated background.

## Features

**Visual**
- Metal GPU-accelerated background with animated 4-color video wash (magenta, blue, teal, yellow)
- 125 particles floating bottom-to-top with depth-correlated size, speed, and opacity
- ~40% of particles fade out as they rise for organic feel
- Per-pixel dithering eliminates color banding
- Translucent glass meter panel with system gauges
- Stream cards with poster art, progress bars, quality badges, and user info
- GeoIP location display per stream (via ipwho.is)
- 2-row grid layout supporting up to 16 simultaneous streams

**Technical**
- Metal fragment shader renders background (gradients + particles) on GPU
- Shared-memory textures for zero-copy readback on Apple Silicon
- Core Graphics overlay for text, cards, and gauges
- Automatic CG-only fallback if Metal is unavailable
- Runtime shader compilation from embedded source as fallback

## Requirements

- macOS 14.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick Install

```bash
cd ~/Downloads/PlexScreensaver
chmod +x install.sh && ./install.sh
```

## Manual Build

```bash
cd PlexScreensaver
xcodegen generate
xcodebuild -scheme PlexScreensaver -configuration Release build
```

Then double-click the `.saver` file to install.

## Configuration

Open **System Settings → Screen Saver**, select "PlexScreensaver", click **Options**:

- **Server URL**: Your Plex server (e.g., `http://192.168.1.100:32400`)
- **Plex Token**: Your auth token (find at app.plex.tv → Settings → Account → XML)

## Architecture

- `PlexScreensaverView` — ScreenSaverView subclass; animation loop + CG overlay rendering
- `MetalBackgroundRenderer` — Metal pipeline: shared textures, shader compilation, GPU rendering
- `BackgroundShaders.metal` — Fragment shader: animated gradient wash, particles, dithering
- `ScreensaverViewModel` — Polls Plex API every 8 seconds
- `PlexFetcher` — Async networking for sessions, identity, posters, and GeoIP
- `ConfigSheetController` — Settings sheet for server URL and token
- `Models` — Data structures for streams and API responses

## Copyright

© 2025-2026 Jason Barton / TikabooLabs. All rights reserved.
