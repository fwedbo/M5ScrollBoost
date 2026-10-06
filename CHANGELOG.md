# Changelog

## 0.90

- Store stable settings identifiers and migrate recognized older labels.
  Missing or unrecognized strengths now default to Balanced.
- Restrict the Studio Display XDR name fallback to reported 0 Hz, so a known
  60 Hz mode no longer qualifies.
- Prevent the controller from displaying boosting when Metal initialization
  failed.
- Use the app name M5 Scroll Boost consistently in the menu and mark Gentle
  experimental. Document the actual Balanced workload.
- Add reproducible build instructions and `--no-open` for build verification.
- Preserve the existing Gentle blit workload and regular three-buffer scheduling.

Historical investigation results apply to the versions and workloads noted
in the README; this version has no new scrolling-performance claim.
