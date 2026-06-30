# scripts/config.R: pipeline constants (sourced by helpers.R consumers and update.R).

# Ordered candidate base URLs for the live source. The canonical path is probed
# first because the bio-web-stats replacement reports on www.bioconductor.org and
# is byte-for-byte identical, so the canonical path is most likely restored.
CANDIDATE_BASE_URLS <- c(
  "https://bioconductor.org/packages/stats/",
  "https://stats.bioconductor.org/packages/stats/"
)

# Pinned Internet Archive raw snapshots per category dir, used while the canonical
# endpoint is in outage. These are the freshest Wayback captures whose payload is
# a real stats file (verified header), one per category. They differ because the
# canonical endpoint stopped updating at different times per category: software
# has no capture past Jan 2026 (it broke first), while data-experiment was still
# captured through May 2026. The conservative anchor (min snapshot month) keeps
# the summary complete for every category. Re-verify when the live endpoint returns.
WAYBACK_SNAPSHOTS <- list(
  "bioc"            = "20260126211628",  # data through Jan 2026
  "data-annotation" = "20260206081913",  # data through Feb 2026 (partial)
  "data-experiment" = "20260510140654",  # data through May 2026 (partial)
  "workflows"       = "20260206052558"   # data through Feb 2026 (partial)
)

RECENT_MONTHS <- 36L
