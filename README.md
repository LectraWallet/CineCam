# CineCam

Pro iPhone camera app in the spirit of Blackmagic Camera — built for iPhone, fully customizable.

**Features**
- **4K 60fps video** (also 1080p / 720p, 24 / 30 / 60 fps) — pick your format
- **Manual controls**: ISO, shutter speed, white balance (Kelvin), exposure bias — all with sliders, plus one-tap AUTO reset
- **Face motion tracking**: on-device Vision face detection draws a live tracking box and keeps focus + exposure locked on the face
- **Cinematic filters**: 12 Core Image looks (Vivid, Noir, Mono, Warm, Cool, Fade, Chrome, Instant, Process, Tonal, Transfer) with intensity control — applied to photos
- **Tap to focus** with on-screen focus indicator
- **Rule-of-thirds grid**, front/back camera switch, focus lock
- **Video stabilization** toggle, record timer, saves to Photos

**Build**
- iOS 17+, SwiftUI + AVFoundation + Vision + Core Image
- GitHub Actions (`.github/workflows/ios.yml`) builds an unsigned IPA — install via Sideloadly / AltStore.
- Bundle ID: `com.cinecam.app`

**Notes**
- 4K 60fps needs iPhone 12 or newer.
- Face tracking is on-device Vision — nothing leaves your phone.
- Filters apply to captured photos; video is recorded unfiltered (ProRes-style pipeline would need a custom encoder).
