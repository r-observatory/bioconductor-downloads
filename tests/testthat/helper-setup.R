# Auto-sourced by testthat before tests run. Sources the pipeline code so tests
# can call the helpers and the orchestrator directly. During test_dir() the
# working directory is tests/testthat, so the repo root is two levels up.
.bioc_root <- normalizePath(file.path(getwd(), "..", ".."))

source(file.path(.bioc_root, "scripts", "config.R"))
source(file.path(.bioc_root, "scripts", "helpers.R"))

.bioc_update <- file.path(.bioc_root, "scripts", "update.R")
if (file.exists(.bioc_update)) source(.bioc_update)

.bioc_bootstrap <- file.path(.bioc_root, "scripts", "bootstrap-from-oldstats.R")
if (file.exists(.bioc_bootstrap)) source(.bioc_bootstrap)

fixture_path <- function(...) {
  file.path(.bioc_root, "tests", "testthat", "fixtures", ...)
}

# Shared test fixtures live in a helper-*.R file so they are visible to EVERY
# test file (top-level defs in a test-*.R file are not shared across files).
mk_con <- function(rows) {
  con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  DBI::dbExecute(con, "CREATE TABLE bioc_downloads_monthly
    (package TEXT, category TEXT, date TEXT, n_distinct_ips INTEGER, n_downloads INTEGER)")
  DBI::dbWriteTable(con, "bioc_downloads_monthly", rows, append = TRUE)
  con
}
mk_monthly <- function(date, ips, dl) {
  data.frame(package = "p", category = "software", date = date,
             n_distinct_ips = ips, n_downloads = dl, stringsAsFactors = FALSE)
}
