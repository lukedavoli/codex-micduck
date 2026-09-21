// Keep null until the DMG has passed signing, notarization and publication checks.
// Then set the direct HTTPS GitHub release asset URL and the displayed version.
export const release = Object.freeze({
  downloadURL: null,
  version: null,
});
