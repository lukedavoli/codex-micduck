import { release } from './release.js';

// Invalid or unfinished configuration leaves the honest, static pending state.
if (typeof release.downloadURL === 'string' && typeof release.version === 'string' && release.version.trim()) {
  try {
    const url = new URL(release.downloadURL);
    if (
      url.protocol === 'https:' &&
      url.hostname === 'github.com' &&
      !url.username && !url.password && !url.port &&
      url.pathname.startsWith('/lukedavoli/codex-micduck/releases/download/') &&
      url.pathname.endsWith('.dmg') &&
      !url.search && !url.hash
    ) {
      const download = document.getElementById('download');
      download.href = url.href;
      download.hidden = false;
      document.getElementById('download-pending').hidden = true;
      document.getElementById('release-note').textContent = `Free & open source · Version ${release.version} · Apple silicon · macOS 15+`;
      document.getElementById('installation-note').hidden = true;
    }
  } catch {
    // A malformed release link must never become a download button.
  }
}
