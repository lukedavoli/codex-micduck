# Product website

Static source for `https://codexmicduck.davolisoftware.com/`, hosted using the existing Davoli Software infrastructure. No build step, external fonts, analytics, or runtime dependencies.

Publish only these files, preserving their relative paths:

- `index.html`
- `style.css`
- `site.js`
- `release.js`
- `assets/duck.png`
- `assets/social-preview-v1.png`

Use a separate origin path or dedicated route for this hostname. Do not replace the existing Davoli Software homepage or shared assets.

The download starts in a pending state. After verifying and publishing the signed, notarized DMG, set `downloadURL` and `version` in `release.js`. The URL must be a direct HTTPS `.dmg` asset in a release of `lukedavoli/codex-micduck`; invalid configuration keeps the pending state visible. Update both values when publishing a new release, and invalidate cached `release.js` as needed.

Serve HTML, JavaScript and CSS with their correct MIME types. Keep short cache lifetimes on `index.html`, `site.js`, and `release.js`, or purge them on deploy. Set `X-Content-Type-Options: nosniff` and `X-Frame-Options: DENY` at the hosting layer. The page supplies a restrictive content-security policy via HTML; an equivalent response header is preferred where supported.

For local preview, serve this directory with any static HTTP server. Inspect at narrow mobile and desktop widths, use the keyboard to follow links and open the permission help, and verify the download state before deploying.

## Link previews and application icon

Open Graph and Twitter metadata live in the initial `index.html`, so link crawlers do not need to run JavaScript. They use the canonical homepage URL and the absolute HTTPS URL of `assets/social-preview-v1.png`. The preview describes the app without claiming that the public installer is available.

The social preview is a static 1200 × 627 PNG composed from the existing duck artwork and the `social-card.html` source in this directory. To regenerate it, render that file in a browser at a 1200 × 627 viewport with device scale factor 1, wait for the image and fonts to load, and save a PNG screenshot of the viewport. The source template is for maintainers and is not deployed. The site does not generate images at runtime. Keep the PNG below 5 MB and deploy it with `Content-Type: image/png`. These dimensions and the Open Graph title, image, description, and URL follow [LinkedIn's sharing guidance](https://www.linkedin.com/help/linkedin/answer/a521928?lang=en).

When changing the preview, publish a new versioned image filename and update both Open Graph image URLs and the Twitter image URL in `index.html`. Purge the cached homepage after deploying. Sharing services keep their own caches; use [LinkedIn Post Inspector](https://www.linkedin.com/post-inspector/) to request a fresh inspection after the public HTTPS page and image are available. Check the image URL directly before sharing.

`assets/duck.png` is the unchanged 1254 × 1254 application artwork. It serves as the browser favicon and Apple touch icon, with its actual dimensions declared in the HTML. The larger social preview does not replace the application icon.
