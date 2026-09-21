# Product website

Static source for `https://codexmicduck.davolisoftware.com/`, hosted using the existing Davoli Software infrastructure. No build step, external fonts, analytics, or runtime dependencies.

Publish only these files, preserving their relative paths:

- `index.html`
- `style.css`
- `site.js`
- `release.js`
- `assets/duck.png`

Use a separate origin path or dedicated route for this hostname. Do not replace the existing Davoli Software homepage or shared assets.

The download starts in a pending state. After verifying and publishing the signed, notarized DMG, set `downloadURL` and `version` in `release.js`. The URL must be a direct HTTPS `.dmg` asset in a release of `lukedavoli/codex-micduck`; invalid configuration keeps the pending state visible. Update both values when publishing a new release, and invalidate cached `release.js` as needed.

Serve HTML, JavaScript and CSS with their correct MIME types. Keep short cache lifetimes on `index.html`, `site.js`, and `release.js`, or purge them on deploy. Set `X-Content-Type-Options: nosniff` and `X-Frame-Options: DENY` at the hosting layer. The page supplies a restrictive content-security policy via HTML; an equivalent response header is preferred where supported.

For local preview, serve this directory with any static HTTP server. Inspect at narrow mobile and desktop widths, use the keyboard to follow links and open the permission help, and verify the download state before deploying.
