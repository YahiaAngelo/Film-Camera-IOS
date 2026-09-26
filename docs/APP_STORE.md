# App Store Submission

Draft listing text and checklist for App Store Connect. Character limits are shown in brackets.

## Listing

**Name** [30]
Film Camera

> **Availability (checked September 26, 2026):** no live app is named exactly "Film Camera" in the US, UK, DE, FR, JP, CN, KR, BR, IN, EG or SA stores. The closest are longer names such as "Film Camera - Vintage Camera" and "Film Camera - Analog Film Cam". Names reserved in App Store Connect but not yet released don't appear in public search, so creating the app record is the final check. If the exact name turns out to be taken, register a longer listing name such as "Film Camera: Analog Looks". The name on the Home Screen stays "Film Camera" either way, because it comes from `CFBundleDisplayName`.

**Subtitle** [30]
Shoot on classic film stocks

**Promotional text** [170]
Around 300 film looks, rendered live in the viewfinder. Real grain, glow and halation. Download your favorite stocks and shoot offline.

**Description** [4000]

```
Film Camera turns your iPhone into an analog camera. Pick a film stock, see its look live in the viewfinder, and take photos that come out exactly as they looked when you pressed the shutter.

AROUND 300 FILM LOOKS
Color negative, slide, black & white, instant, cinema print and more. Browse and search the full collection, and download the stocks you love to keep them available offline. Eight popular looks are built in, so you can start shooting right away.

LIVE, NOT AFTERWARDS
Every frame is processed on the GPU with Metal, so the look is live in the viewfinder. Full-resolution photos go through the same pipeline, so what you see is what you get.

FILM CHARACTER
• Organic film grain that moves like projected film
• Glow and halation around highlights
• Vignette and faded blacks
• Adjustable film strength

FINE CONTROL
Exposure, contrast, highlights, shadows, saturation, warmth and tint, in a sheet that keeps the viewfinder live while you adjust.

A REAL CAMERA
Lens switching, pinch to zoom, tap to focus, flash, grid and the front camera. Photos are saved to your library with their original camera metadata.

PRIVATE BY DESIGN
No account, no ads, no tracking. Your photos never leave your device.
```

**Keywords** [100]

```
analog,film,grain,lut,vintage,retro,35mm,halation,emulation,filter,negative,slide,darkroom,disposable
```

> Don't put film brand names (Kodak, Fuji, Portra…) in the keywords, name or subtitle. They're third-party trademarks, and using them in metadata is a common rejection reason (Guideline 2.3.7 / 5.2.1). Mentioning stocks inside the app to describe a look is a separate question; see Review risks below.

**Category:** Photo & Video (primary)
**Age rating:** 4+ (answer "None" to every questionnaire item)
**Price:** your choice
**Copyright:** 2026 Yahia

**Support URL:** https://github.com/YahiaAngelo/Film-Camera/issues
**Marketing URL:** https://github.com/YahiaAngelo/Film-Camera
**Privacy Policy URL:** https://github.com/YahiaAngelo/Film-Camera/blob/main/PRIVACY.md

## App Privacy ("nutrition label")

Select **Data Not Collected**. The app has no analytics or accounts, photos stay on device, and network requests only download public LUT files from GitHub.

The bundled `PrivacyInfo.xcprivacy` declares no tracking and no collected data. It also declares the one required-reason API the app uses: `UserDefaults` with reason `CA92.1`.

## Export compliance

`ITSAppUsesNonExemptEncryption` is set to `NO`: the app only uses HTTPS through `URLSession`, so App Store Connect won't ask about encryption on each upload.

## Screenshots

Ready-to-upload 6.9" screenshots (1320 × 2868, no alpha channel) are in [`app-store/screenshots`](app-store/screenshots):

| # | File | Headline |
|---|------|----------|
| 1 | `01-shoot-on-film.png` | Shoot on film. |
| 2 | `02-black-and-white.png` | Timeless black & white. |
| 3 | `03-every-film.png` | Every film. Offline. |
| 4 | `04-glow-halation.png` | Glow & halation. |
| 5 | `05-what-you-see.png` | What you see is what you get. |

App Store Connect scales 6.9" screenshots down for smaller iPhones, so this one set is enough.

They show the simulator's built-in sample scene. To use your own photos, take real-device shots and compose them with the same script.

### Regenerating

1. Run the Debug build on the **iPhone 18 Pro Max** simulator. Screenshots from a 6.9" simulator are exactly 1320 × 2868.
2. Launch it with a film, adjustments and optional sheet passed as launch arguments. Debug builds accept `-FCOpenSheet library|adjustments`; Release builds compile it out.
   ```sh
   xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100
   xcrun simctl launch booted io.github.yahiaangelo.Film-Camera \
     -selectedFilm "luts/bw/kodak_tri-x_400.cube" -FCOpenSheet adjustments
   xcrun simctl io booted screenshot raw/2-bw.png
   ```
3. Name the raw screenshots `1-portra`, `2-bw`, `3-library`, `4-adjust` and `5-velvia`, then compose:
   ```sh
   swift scripts/make-app-store-screenshots.swift raw docs/app-store/screenshots
   ```
   Headlines and subtitles are set in the `pages` array at the top of the script.

## Review notes

```
Film Camera is a camera app that applies film emulation LUTs to the live camera preview using Metal. No account or login is required.

To test: allow camera access, choose a film from the strip above the shutter, and take a photo (it is saved to Photos with add-only permission). Tap the film stack icon (top right) to browse and download more films; downloads come from a public GitHub repository of .cube LUT files.
```

## Review risks

- **Trademarked film names.** Film names such as "Kodak Portra 400" come from the LUT collection and appear in the app to describe each look. Apps like this commonly ship this way, but Apple can still raise Guideline 5.2.1. If that happens, the usual fix is a short disclaimer in the app. One is already in the README.
- **Downloaded content.** LUTs are data files, not executable code, so Guideline 2.5.2 doesn't apply.

## Checklist before uploading

- [ ] Signing team set to your App Store team (Signing & Capabilities)
- [ ] App ID `io.github.yahiaangelo.Film-Camera` registered, and the app record created in App Store Connect
- [ ] `MARKETING_VERSION` (1.0) and `CURRENT_PROJECT_VERSION` (1) set; bump the build number for every upload
- [ ] Product → Archive → Distribute App → App Store Connect
- [ ] Screenshots, listing text, privacy answers and review notes filled in
- [ ] Tested on a device from a TestFlight build
