# Changelog

## 1.0

- Remove Continuous mode; saved Continuous selections migrate to On scroll.
- Keep Gentle and Balanced; saved Strong selections migrate to Balanced.
- Default new installations and missing or unrecognized strengths to Gentle.
- Store stable settings identifiers and migrate recognized older labels.
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
