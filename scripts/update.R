#!/usr/bin/env Rscript
# scripts/update.R: change-gated bioconductor-downloads producer.
#
# Every run resolves the source (live canonical endpoint, or the Internet Archive
# while it is in outage), diffs per-category content identities, and either
# heartbeats (no change) or does a full rebuild of every year shard plus the
# rolling recent and summary shards. This script only writes into out/; the
# workflow uploads. run_update(io, out_dir) takes an injectable io for offline
# testing.

options(timeout = 600)

suppressPackageStartupMessages({
  library(DBI); library(RSQLite); library(jsonlite)
})

.this_file <- function() {
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of) && nzchar(of)) return(normalizePath(of))
  }
  a <- commandArgs(FALSE)
  f <- sub("^--file=", "", grep("^--file=", a, value = TRUE))
  if (length(f) == 1L && nzchar(f)) return(normalizePath(f))
  NA_character_
}
.script_dir <- { tf <- .this_file(); if (!is.na(tf)) dirname(tf) else "scripts" }
if (!exists("category_tuples", mode = "function")) {
  source(file.path(.script_dir, "config.R"))
  source(file.path(.script_dir, "helpers.R"))
}

PUBLISH_REPO <- "r-observatory/bioconductor-downloads"
SUMMARY_COLS <- c("package", "package_lower", "category", "download_score",
                  "total_last_month", "total_12mo",
                  "rank_score", "rank_downloads_12mo", "trend")

iso <- function(t) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

empty_monthly <- function() data.frame(
  package = character(0), category = character(0), date = character(0),
  n_distinct_ips = integer(0), n_downloads = integer(0), stringsAsFactors = FALSE)
empty_yearly <- function() data.frame(
  package = character(0), category = character(0), year = integer(0),
  n_distinct_ips_year = integer(0), n_downloads_year = integer(0), stringsAsFactors = FALSE)

init_monthly <- function(con) {
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS bioc_downloads_monthly
    (package TEXT, category TEXT, date TEXT, n_distinct_ips INTEGER, n_downloads INTEGER)")
}
load_monthly <- function(con, rows) {
  if (nrow(rows) == 0) return(invisible())
  DBI::dbWriteTable(con, "bioc_downloads_monthly",
    rows[c("package", "category", "date", "n_distinct_ips", "n_downloads")], append = TRUE)
}
embed_summary <- function(recent_path, summary_df) {
  con <- DBI::dbConnect(RSQLite::SQLite(), recent_path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbExecute(con, "DROP TABLE IF EXISTS bioc_downloads_summary")
  DBI::dbExecute(con, "CREATE TABLE bioc_downloads_summary (
    package TEXT, package_lower TEXT, category TEXT,
    download_score REAL, total_last_month INTEGER, total_12mo INTEGER,
    rank_score INTEGER, rank_downloads_12mo INTEGER, trend REAL,
    PRIMARY KEY (package, category))")
  if (nrow(summary_df) > 0) {
    DBI::dbWriteTable(con, "bioc_downloads_summary", summary_df, append = TRUE)
  }
}
coverage <- function(rows) {
  if (nrow(rows) == 0) return(list(rows = 0L, date_min = NA, date_max = NA))
  list(rows = nrow(rows), date_min = min(rows$date), date_max = max(rows$date))
}

# Parse one downloaded category file into split monthly/yearly frames.
parse_category_local <- function(local_file, label) {
  text <- paste(readLines(local_file, warn = FALSE), collapse = "\n")
  parsed <- parse_stats_tab(text, label)
  sp <- split_monthly_yearly(parsed)
  sp$monthly <- drop_future_placeholders(sp$monthly)
  list(monthly = sp$monthly, yearly = sp$yearly, source_rows = nrow(parsed))
}

run_update <- function(io, out_dir, force_full = FALSE) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  manifest_path <- file.path(out_dir, "manifest.json")

  rel_exists <- io$release_exists()
  if (rel_exists) {
    st <- io$release_download("manifest.json", out_dir)
    if (!identical(st, 0L) || !file.exists(manifest_path)) {
      stop("release 'current' exists but manifest.json could not be downloaded; aborting")
    }
  }
  prev <- if (file.exists(manifest_path))
    jsonlite::fromJSON(manifest_path, simplifyVector = FALSE) else list()
  prev_sources <- prev$source_files %||% list()
  prev_shards  <- prev$shards %||% list()
  if (isTRUE(force_full)) prev_sources <- list()

  now <- io$now()
  resolved <- io$resolve_source()
  kind <- resolved$kind
  curr <- resolved$source_files

  heartbeat <- function(src_kind) {
    out <- if (length(prev) > 0) prev else list()
    out$last_checked   <- iso(now)
    out$source_kind    <- src_kind
    out$live_available <- identical(kind, "live")
    if (length(curr) > 0) out$source_files <- curr
    out$changed_shards <- list()
    write_manifest(manifest_path, out)
    write_release_notes(file.path(out_dir, "release_notes.md"), out)
    list(changed_shards = character(0), manifest = out)
  }

  if (identical(kind, "none")) {
    if (length(prev) == 0)
      stop("no Bioconductor stats source is reachable and no prior release exists; cannot bootstrap")
    return(heartbeat("frozen"))
  }

  changed <- diff_source_state(prev_sources, curr)
  if (length(changed) == 0) return(heartbeat(kind))

  # Full rebuild.
  src_dir <- file.path(out_dir, "_src")
  dir.create(src_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(src_dir, recursive = TRUE), add = TRUE)
  local <- io$fetch_sources(names(curr), src_dir)

  cts <- category_tuples()
  monthly_parts <- list(); yearly_parts <- list(); source_rows_read <- 0L
  for (ct in cts) {
    key <- category_file(ct)
    lf <- local[[key]]
    if (is.null(lf) || !file.exists(lf)) next
    p <- parse_category_local(lf, ct$label)
    monthly_parts[[ct$label]] <- p$monthly
    yearly_parts[[ct$label]]  <- p$yearly
    source_rows_read <- source_rows_read + p$source_rows
  }
  monthly <- if (length(monthly_parts)) do.call(rbind, monthly_parts) else empty_monthly()
  yearly  <- if (length(yearly_parts))  do.call(rbind, yearly_parts)  else empty_yearly()
  rownames(monthly) <- NULL; rownames(yearly) <- NULL

  anchor <- anchor_month(monthly, resolved$capture_month %||% NA_character_)
  if (is.na(anchor)) stop("no complete month available before the capture month")

  changed_shards <- character(0); shard_updates <- list()
  years <- sort(unique(c(as.integer(substr(monthly$date, 1, 4)), yearly$year)))
  for (yr in years) {
    shard <- sprintf("bioconductor-%04d.db", yr)
    m_yr <- monthly[substr(monthly$date, 1, 4) == sprintf("%04d", yr), , drop = FALSE]
    y_yr <- yearly[yearly$year == yr, , drop = FALSE]
    export_shard(file.path(out_dir, shard), m_yr, y_yr)
    changed_shards <- c(changed_shards, shard)
    shard_updates[[shard]] <- coverage(m_yr)
  }

  con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  init_monthly(con); load_monthly(con, monthly)

  recent_path <- file.path(out_dir, "bioconductor-recent.db")
  recent_rows <- extract_recent_monthly(con, anchor, RECENT_MONTHS)
  export_shard(recent_path, recent_rows)

  summary_df <- DBI::dbGetQuery(con, summary_sql(anchor))
  summary_df <- summary_df[SUMMARY_COLS]
  export_summary_shard(file.path(out_dir, "bioconductor-summary.db"), summary_df)
  embed_summary(recent_path, summary_df)
  changed_shards <- c(changed_shards, "bioconductor-recent.db", "bioconductor-summary.db")
  shard_updates[["bioconductor-recent.db"]] <- coverage(recent_rows)

  out <- list(
    tag                 = sprintf("v%s", format(now, "%Y%m%d-%H%M%S", tz = "UTC")),
    generated_at        = iso(now),
    last_checked        = iso(now),
    last_changed        = iso(now),
    source_kind         = kind,
    live_available      = identical(kind, "live"),
    candidate_base_urls = as.list(CANDIDATE_BASE_URLS),
    granularities       = list("monthly"),
    data_through        = list(monthly = substr(anchor, 1, 7)),
    source_files        = curr,
    changed_shards      = as.list(changed_shards),
    shards              = merge_shard_coverage(prev_shards, shard_updates),
    summary             = list(
      categories       = as.list(vapply(cts, function(ct) ct$label, character(1))),
      packages         = length(unique(summary_df$package)),
      source_rows_read = source_rows_read))
  write_manifest(manifest_path, out)
  write_release_notes(file.path(out_dir, "release_notes.md"), out)
  list(changed_shards = changed_shards, manifest = out)
}
