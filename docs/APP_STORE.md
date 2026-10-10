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
   xcrun simctl launch booted io.github.yahiaangelo.FilmCamera \
     -selectedFilm "luts/bw/kodak_tri-x_400.cube" -FCOpenSheet adjustments
   xcrun simctl io booted screenshot raw/2-bw.png
   ```
3. Name the raw screenshots `1-portra`, `2-bw`, `3-library`, `4-adjust` and `5-velvia`, then compose:
   ```sh
   swift scripts/make-app-store-screenshots.swift raw docs/app-store/screenshots
   ```
   Headlines and subtitles are set in the `pages` array at the top of the script.

## Review notes

Paste this into **App Review Information → Notes**. It answers the Guideline 2.1 "Information Needed" questions App Review asked for on the first submission, and attach the screen recording to your reply.

```
1. Screen recording
Attached. It starts at launch and shows the full user flow: camera and photo permissions, choosing films, live adjustments, taking and saving a photo, browsing and downloading films, and the front camera. The app has no accounts, no user-generated content and no paid content.

2. Purpose and target audience
Film Camera is a camera app for people who love the look of analog film: hobbyist and enthusiast photographers, and anyone who wants their photos to look like classic film straight out of the camera, without editing afterwards. It applies film emulation color profiles (3D LUTs) to the live camera preview in real time on the GPU, adds film characteristics such as grain, glow, halation and vignette, and saves full-resolution photos that match what was shown in the viewfinder.

3. Setup and main features
No login, account or sample files are required.
- Launch the app and allow camera access. The live preview appears with a film applied.
- Tap films in the strip above the shutter button to change the look live.
- Tap the sliders icon (top right) to adjust exposure, contrast, color, grain, glow, halation and vignette.
- Tap the shutter to take a photo. Allow "Add to Photos" and the processed photo is saved to the photo library.
- Tap the film stack icon (top right) to browse the film catalog, search, and download films for offline use ("Download All" downloads the whole catalog).
- Eight films are built in, so the app works fully offline.

4. External services
The only external service is GitHub (raw.githubusercontent.com), which hosts the public film catalog (a JSON file), the film LUT files (.cube color lookup tables) and their preview images. These are static data files, not executable code, and no personal data is sent. All image processing happens on device using Apple frameworks (AVFoundation, Metal, Photos). The app does not use authentication, payments, analytics, advertising or AI services.

5. Regional differences
There are none. The app works the same in all regions.

6. Third-party material
The film looks are open-source film emulation LUTs from the G'MIC project (gmic.eu), redistributed in the public Film-Luts collection (github.com/YahiaAngelo/Film-Luts). They are original color transforms created by the G'MIC community to approximate the look of classic film stocks, and they contain no content from film manufacturers. Film stock names are used only to describe which look each LUT emulates. The app shows a notice in the film library stating that film names are trademarks of their respective owners, and that the app is not affiliated with or endorsed by any manufacturer. It does not use any manufacturer logos or branding.
```

### Screen recording shot list

Record with iOS Screen Recording on a physical iPhone running the latest iOS. First delete and reinstall the build, so the permission prompts appear.

1. Start on the Home Screen and launch Film Camera.
2. Allow camera access.
3. Tap 3–4 films in the strip, including one black-and-white film.
4. Pinch to zoom, tap the lens buttons, and tap to focus.
5. Open Adjust and change Grain, Glow and Exposure. Tap Reset, then Done.
6. Take a photo and allow Add to Photos. Tap the thumbnail to show it in Photos.
7. Open Films and search. Download a film and use it. Scroll to the bottom to show the trademark notice.
8. In My Films, reorder a film and remove one.
9. Tap Download All, confirm, then cancel.
10. Switch to the front camera and take a selfie.

## Review risks

- **Trademarked film names.** Film names such as "Kodak Portra 400" come from the LUT collection and appear in the app to describe each look. The film library shows a trademark and non-affiliation notice (below the Explore grid and in the My Films footer). Apple can still raise Guideline 5.2.1; if it does, the next step would be renaming looks to generic names.
- **Downloaded content.** LUTs are data files, not executable code, so Guideline 2.5.2 doesn't apply.

## Checklist before uploading

- [ ] Signing team set to your App Store team (Signing & Capabilities)
- [ ] App ID `io.github.yahiaangelo.FilmCamera` registered, and the app record created in App Store Connect
- [ ] `MARKETING_VERSION` (1.0) and `CURRENT_PROJECT_VERSION` (1) set; bump the build number for every upload
- [ ] Product → Archive → Distribute App → App Store Connect
- [ ] Screenshots, listing text, privacy answers and review notes filled in
- [ ] Tested on a device from a TestFlight build
