# scripts/config.R: pipeline constants (sourced by helpers.R consumers and update.R).

# Ordered candidate base URLs for the live source. The canonical path is probed
# first because the bio-web-stats replacement reports on www.bioconductor.org and
# is byte-for-byte identical, so the canonical path is most likely restored.
CANDIDATE_BASE_URLS <- c(
  "https://bioconductor.org/packages/stats/",
  "https://stats.bioconductor.org/packages/stats/"
)

# Pinned Internet Archive raw snapshots per category dir, used while the canonical
# endpoint is in outage. Confirm/refresh these during implementation (Task 12).
WAYBACK_SNAPSHOTS <- list(
  "bioc"            = "20260126211628",
  "data-annotation" = "20260126211628",
  "data-experiment" = "20260126211628",
  "workflows"       = "20260126211628"
)

RECENT_MONTHS <- 36L
