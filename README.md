# PlexScreensaver for macOS

A GPU-accelerated macOS screen saver that displays live Plex Media Server activity with a cinematic animated background, stream cards with poster art, system monitoring gauges, and bandwidth tracking.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

<!-- Add your screenshot here -->
<!-- ![Screenshot](screenshots/screensaver.png) -->

## What Does It Do?

When your Mac's screen saver activates, instead of a generic animation you'll see a live dashboard of your Plex server:

- **What's playing** — Movie and TV show poster art, titles, who's watching, playback progress, video quality (4K, HDR, 1080p), and whether it's transcoding or direct playing
- **Where they're watching from** — City and state for remote viewers, "Local Network" for local ones
- **Server health** — CPU and RAM gauges for your Mac, plus a live bandwidth chart
- **Beautiful background** — Animated color wash with floating particles, all rendered on your GPU

It supports up to 16 simultaneous streams displayed in a 2-row grid.

## Requirements

- A Mac running **macOS 14.0 (Sonoma)** or later
- A **Plex Media Server** on your network (or accessible remotely)
- **Xcode** (free from the App Store) — needed to compile the screen saver
- **Homebrew** — a package manager for macOS (installation covered below)

## Installation

### Step 1: Install Homebrew (if you don't have it)

Homebrew is a free tool that makes it easy to install developer tools on your Mac. If you already have it, skip to Step 2.

1. Open **Terminal** (press `⌘ Space`, type "Terminal", press Enter)
2. Paste this command and press Enter:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

3. Follow the on-screen instructions. It may ask for your Mac password — this is normal. When you type your password, nothing will appear on screen (no dots or stars) — just type it and press Enter.
4. When it finishes, it may tell you to run a command to add Homebrew to your path. If so, copy and run that command.

### Step 2: Install Xcode (if you don't have it)

Xcode is Apple's free development tool. It's a large download (~7 GB) but is required to compile the screen saver.

1. Open the **App Store** on your Mac
2. Search for **Xcode**
3. Click **Get** / **Install**
4. Wait for it to download and install (this can take a while on slower connections)
5. **Open Xcode once** after installing — it will ask you to agree to a license and install additional components. Click through these prompts and wait for it to finish.

### Step 3: Install XcodeGen

XcodeGen is a small tool that generates the project file needed to build the screen saver.

1. Open **Terminal**
2. Run:

```bash
brew install xcodegen
```

### Step 4: Download and Build the Screen Saver

1. Open **Terminal**
2. Run these commands one at a time (you can copy and paste each line):

```bash
git clone https://github.com/tikaboolabs/PlexScreensaver.git
```

```bash
cd PlexScreensaver
```

```bash
chmod +x install.sh && ./install.sh
```

3. The script will:
   - Build the screen saver (this takes about a minute)
   - Install it to your Mac automatically
   - Open Screen Saver settings when it's done

If you see **"BUILD SUCCEEDED"** and **"Done!"** — you're all set.

### Step 5: Configure Your Plex Connection

After the install script finishes, it will open Screen Saver settings. If it didn't, open them manually:

1. Open **System Settings** (click the Apple menu  → System Settings)
2. Click **Screen Saver** in the sidebar
3. Scroll down and select **PlexScreensaver**
4. Click **Options...**
5. Fill in two fields:

| Field | What to enter | Example |
|-------|--------------|---------|
| **Server URL** | Your Plex server's address with port | `http://192.168.1.100:32400` |
| **Plex Token** | Your authentication token (see below) | `abc123def456` |

6. Click **OK** to save

### Step 6: Set It as Your Active Screen Saver

1. In **System Settings → Screen Saver**, make sure **PlexScreensaver** is selected (it should have a checkmark or be highlighted)
2. Optionally adjust when the screen saver activates under **System Settings → Lock Screen → "Start Screen Saver when inactive"**

That's it — your screen saver is installed and will activate after the configured idle time.

## How to Find Your Plex Token

Your Plex token is a short text string (~20 characters) that lets the screen saver talk to your Plex server. Here's how to find it:

**Easiest method:**

1. Open your Plex server in a **web browser** (e.g., `http://192.168.1.100:32400/web`)
2. Navigate to any movie or TV show
3. Click the **three dots** menu (**⋯**) on the item
4. Click **Get Info**
5. Click **View XML** (at the bottom of the info panel)
6. A new tab opens with XML data — look at the **URL in the address bar**
7. Find `X-Plex-Token=` in the URL — the text after the `=` is your token

**Alternative method (Browser DevTools):**

1. Open your Plex server in a web browser
2. Press **F12** (or **⌘⌥I** on Mac) to open Developer Tools
3. Click the **Network** tab
4. Play something or click around in Plex
5. Click any network request to your server
6. Look for `X-Plex-Token` in the URL parameters or request headers

## How to Find Your Server URL

Your server URL is the address your Mac uses to reach your Plex server.

- If Plex runs on the **same Mac**: `http://localhost:32400`
- If Plex runs on **another computer on your network**: `http://192.168.x.x:32400` (replace with that computer's IP address)
- To find the IP: on the Plex server machine, go to **System Settings → Wi-Fi** (or Network) and look for the IP address

The port is almost always `32400` unless you changed it.

## Updating

If a new version is released, update by running these commands in Terminal:

```bash
cd PlexScreensaver
git pull
chmod +x install.sh && ./install.sh
```

## What You'll See

| Element | Where on screen | What it shows |
|---------|----------------|---------------|
| Server name + status dot | Top center | Green dot = connected, red = can't reach server |
| Clock | Top right | Current time and date (subtle, ghosted) |
| Stream cards | Center | Poster art, title, episode info, who's watching, their location, bandwidth |
| Progress bar | Bottom of each poster | Gold bar showing how far through the movie/episode |
| Quality badge | Top-right of poster | Resolution (4K, 1080p, etc.) and HDR status |
| CPU gauge | Bottom panel, left | How hard your Mac's processor is working |
| RAM gauge | Bottom panel, center | How much memory your Mac is using |
| Bandwidth chart | Bottom panel, right | Current network speed + 60-second history |
| Stream count | Below server name | "3 ACTIVE STREAMS" or "NO ACTIVE STREAMS" |

When nothing is playing, the screen saver still shows the animated background, clock, and system gauges.

## Troubleshooting

**The screen saver doesn't appear in System Settings:**
- Make sure the build completed successfully (look for "BUILD SUCCEEDED" in Terminal)
- Try running the install script again: `cd PlexScreensaver && ./install.sh`

**"CONFIGURE IN SCREEN SAVER OPTIONS" message:**
- You haven't entered your server URL and token yet. Go to System Settings → Screen Saver → Options and fill them in.

**Red status dot / can't connect:**
- Double-check your server URL includes `http://` and the port (`:32400`)
- Make sure your Plex server is running
- Try opening the URL in a web browser to verify it works: `http://YOUR_IP:32400`

**No streams showing but connected (green dot):**
- This is normal when nobody is watching anything. Start playing something in Plex and the stream card will appear within 8 seconds.

**Screen saver is laggy or slow:**
- This shouldn't happen on any Mac made in the last 5-6 years. The background animation runs on your GPU. If you're on a very old Mac, the screen saver will automatically fall back to a simpler rendering mode.

**Build fails with an error:**
- Make sure you opened Xcode at least once and accepted the license agreement
- Try running: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (enter your password when asked)

## Uninstalling

To remove the screen saver:

1. Open **Terminal**
2. Run:

```bash
rm -rf ~/Library/Screen\ Savers/PlexScreensaver.saver
```

3. Open **System Settings → Screen Saver** and choose a different screen saver

Your Plex credentials are stored in your user preferences and will be removed automatically.

## Features (Technical)

- Metal GPU-accelerated background with animated 4-color gradient wash and 125 floating particles
- Half-resolution background rendering saves ~75% GPU memory with no visible difference
- Shared-memory textures for zero-copy readback on Apple Silicon
- Poster images downsampled to display size (~85% RAM savings per image)
- Poster cache eviction for long-running sessions
- Automatic fallback to CPU rendering if Metal is unavailable
- GeoIP location lookup for remote viewers (via ipwho.is)
- Catmull-Rom smoothed bandwidth sparkline with 60-second history

## Project Structure

```
PlexScreensaver/
├── project.yml                     # XcodeGen project spec
├── install.sh                      # One-step build + install script
└── PlexScreensaver/
    ├── PlexScreensaverView.swift       # Main screen saver view + animation loop
    ├── MetalBackgroundRenderer.swift   # GPU gradient wash + particles
    ├── BackgroundShaders.metal         # Metal fragment shader
    ├── ScreensaverViewModel.swift      # Plex API polling + data management
    ├── PlexFetcher.swift               # Async networking (sessions, posters, GeoIP)
    ├── ConfigSheetController.swift     # Options sheet for server URL + token
    └── Models.swift                    # Data models + API response types
```

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
