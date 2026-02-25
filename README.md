# PlexScreensaver for macOS

A GPU-accelerated macOS screen saver that displays live Plex Media Server activity with a cinematic animated background, stream cards with poster art, system monitoring gauges, and bandwidth tracking.

## Features

**Live Plex Monitoring**
- Real-time stream cards showing what's playing, who's watching, and playback progress
- Poster art with animated shimmer placeholders while loading
- Quality badges (4K, HDR, 1080p, etc.) and transcoding/direct play indicators
- GeoIP location display per stream (city, state via ipwho.is)
- Bandwidth sparkline with 60-second history and Catmull-Rom smoothing
- Support for up to 16 simultaneous streams in a 2-row grid layout

**Visual Design**
- Metal GPU-accelerated background with animated 4-color wash (magenta, blue, teal, yellow)
- 125 floating particles with depth-correlated size, speed, and opacity
- ~40% of particles fade as they rise for organic depth
- Per-pixel dithering eliminates color banding
- Translucent glass panel with CPU and RAM arc gauges
- Ghosted clock with date display
- Smooth card fade-in/fade-out transitions when streams start and stop
- Poster-sampled accent colors for each stream card

**Technical**
- Metal fragment shader renders background (gradients + particles) on GPU
- Half-resolution background rendering saves ~75% memory with no visible difference
- Shared-memory textures for zero-copy readback on Apple Silicon
- Core Graphics overlay for text, cards, and gauges
- Automatic CG-only fallback if Metal is unavailable
- Runtime shader compilation from embedded source as additional fallback
- Poster images downsampled to display size (~85% RAM savings per image)
- Cached DateFormatters and color spaces to minimize per-frame allocations
- Poster cache eviction for long-running sessions

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac with Metal support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for building from source

## Installation

### Quick Install (from source)

```bash
brew install xcodegen
git clone https://github.com/tikaboolabs/PlexScreensaver.git
cd PlexScreensaver
chmod +x install.sh && ./install.sh
```

### Manual Build

```bash
brew install xcodegen
git clone https://github.com/tikaboolabs/PlexScreensaver.git
cd PlexScreensaver
xcodegen generate
xcodebuild -scheme PlexScreensaver -configuration Release build
```

The built `.saver` file will be in `~/Library/Developer/Xcode/DerivedData/PlexScreensaver-*/Build/Products/Release/`. Double-click it to install, or copy it to `~/Library/Screen Savers/`.

## Configuration

1. Open **System Settings > Screen Saver**
2. Select **PlexScreensaver**
3. Click **Options**
4. Enter your Plex server URL and token:

| Field | Example | Notes |
|-------|---------|-------|
| Server URL | `http://192.168.1.100:32400` | Your Plex server's local or remote address |
| Plex Token | *(your token)* | Find at: open any media in Plex Web, view XML, look for `X-Plex-Token` in the URL |

Credentials are stored in macOS UserDefaults (per-user, not in source code).

## What It Displays

| Element | Location | Description |
|---------|----------|-------------|
| Server name + status dot | Top center | Green = connected, red = unreachable, pulsing glow |
| Clock | Top right | Time, AM/PM, and date (ghosted at 18% opacity) |
| Stream cards | Center | Poster art, title, subtitle (S01E03 format for TV), user, location, bandwidth |
| Progress bar | Bottom of each poster | Gold capsule bar showing playback position |
| Quality badge | Top-right of poster | Resolution and HDR status |
| CPU gauge | Bottom panel, left | Half-arc gauge with percentage |
| RAM gauge | Bottom panel, center | Half-arc gauge with percentage |
| Bandwidth | Bottom panel, right | Current Mbps + 60-second sparkline chart |
| Stream count | Below server name | "3 ACTIVE STREAMS" / "NO ACTIVE STREAMS" / "CONFIGURE IN SCREEN SAVER OPTIONS" |

## Architecture

```
PlexScreensaverView          ScreenSaverView subclass — animation loop, CG rendering
├── MetalBackgroundRenderer   Metal pipeline: GPU gradient wash + particles
│   └── BackgroundShaders.metal   Fragment shader (also embedded as Swift string fallback)
├── ScreensaverViewModel      Polls Plex API every 8s, manages poster + GeoIP caches
│   └── PlexFetcher           Async networking: sessions, identity, posters, GeoIP
├── ConfigSheetController     Options sheet for server URL and token
└── Models                    SSStream, SSServerState, API response Codables
```

## How It Works

1. **Every 8 seconds**, the view model polls your Plex server's `/status/sessions` endpoint
2. Active streams are parsed into `SSStream` objects with title, user, quality, progress, and player info
3. Poster images are fetched via Plex's transcode endpoint, downsampled to display size, and cached
4. External IPs are resolved to city/state via ipwho.is (local IPs show "Local Network")
5. **Every frame (30fps)**, the Metal shader renders the animated background at half resolution
6. Core Graphics draws the cards, gauges, sparkline, clock, and text over the GPU background
7. System CPU and RAM stats are sampled once per second via Mach host APIs

## License

Copyright 2025-2026 Jason Barton / TikabooLabs. All rights reserved.
