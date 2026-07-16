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
  summary_out <- file.path(out_dir, "bioconductor-summary.db")
  export_summary_shard(summary_out, summary_df)
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
  # Preserve the frozen oldstats archive block across runs (built once, never here).
  if (!is.null(prev$oldstats)) out$oldstats <- prev$oldstats
  # Integrity / completeness core for the summary DB the downstream merge pulls.
  # Computed from the finalized on-disk bioconductor-summary.db (written above) so
  # db_bytes/db_sha256 describe the exact bytes uploaded to the release. Every run
  # that reaches here re-fetches all category source files and loads the full
  # monthly history in memory; the summary's trailing-12-month window sits inside
  # that complete dataset, so it is a full snapshot: complete = TRUE.
  integrity_core <- summary_integrity_core(summary_out, complete = TRUE)
  write_manifest(manifest_path, out, core = integrity_core)
  write_release_notes(file.path(out_dir, "release_notes.md"), out)
  list(changed_shards = changed_shards, manifest = out)
}

with_retry <- function(expr, tries = 3L, wait = 3) {
  for (i in seq_len(tries)) {
    val <- tryCatch(force(expr), error = function(e) e)
    if (!inherits(val, "error")) return(val)
    if (i < tries) Sys.sleep(wait * i)
  }
  stop(val)
}

# HEAD a URL; return list(ok, etag, last_modified) without downloading the body.
http_head <- function(url) {
  h <- curl::new_handle(nobody = TRUE, followlocation = TRUE, timeout = 60L)
  r <- tryCatch(curl::curl_fetch_memory(url, handle = h), error = function(e) NULL)
  if (is.null(r) || r$status_code >= 400) return(list(ok = FALSE))
  hdr <- curl::parse_headers_list(r$headers)
  list(ok = TRUE, etag = hdr[["etag"]] %||% "", last_modified = hdr[["last-modified"]] %||% "")
}

default_io <- function() {
  cts <- category_tuples()
  state <- new.env(parent = emptyenv())
  state$kind <- NULL; state$base <- NULL  # remembered between resolve and fetch

  resolve_source <- function() {
    # Try each candidate base: it must serve a valid (200) software file.
    for (base in CANDIDATE_BASE_URLS) {
      probe <- http_head(live_url(base, cts[[1]]))
      if (isTRUE(probe$ok)) {
        state$kind <- "live"; state$base <- base
        sf <- list()
        for (ct in cts) {
          h <- http_head(live_url(base, ct))
          id <- paste0(h$etag %||% "", "|", h$last_modified %||% "")
          sf[[category_file(ct)]] <- list(hash = id, etag = h$etag %||% "",
            last_modified = h$last_modified %||% "", via = "live")
        }
        # Live: all categories are fetched now, so the in-progress month is now.
        return(list(kind = "live", source_files = sf,
                    capture_month = format(Sys.time(), "%Y-%m")))
      }
    }
    # Fall back to pinned Wayback snapshots.
    if (length(WAYBACK_SNAPSHOTS) > 0) {
      state$kind <- "wayback"; state$base <- NULL
      sf <- list(); months <- character(0)
      for (ct in cts) {
        ts <- WAYBACK_SNAPSHOTS[[ct$dir]]
        sf[[category_file(ct)]] <- list(hash = paste0("wayback:", ts),
          via = paste0("wayback:", ts))
        months <- c(months, paste0(substr(ts, 1, 4), "-", substr(ts, 5, 6)))
      }
      # Snapshots can differ per category; the earliest snapshot month is the most
      # conservative in-progress month, so the anchor is complete for every category.
      return(list(kind = "wayback", source_files = sf, capture_month = min(months)))
    }
    list(kind = "none", source_files = list(), capture_month = NULL)
  }

  fetch_sources <- function(paths, dir) {
    stats::setNames(vapply(paths, function(p) {
      ct <- Filter(function(x) category_file(x) == p, cts)[[1]]
      url <- if (identical(state$kind, "live")) live_url(state$base, ct)
             else wayback_raw_url(WAYBACK_SNAPSHOTS[[ct$dir]], ct)
      dest <- file.path(dir, gsub("/", "_", p))
      with_retry(utils::download.file(url, dest, mode = "wb", quiet = TRUE))
      dest
    }, character(1)), paths)
  }

  list(
    release_exists = function() {
      st <- suppressWarnings(system2("gh",
        c("release", "view", "current", "--repo", PUBLISH_REPO),
        stdout = FALSE, stderr = FALSE))
      identical(as.integer(st), 0L)
    },
    release_download = function(pattern, dir) {
      for (i in seq_len(3L)) {
        st <- suppressWarnings(system2("gh",
          c("release", "download", "current", "--repo", PUBLISH_REPO,
            "--pattern", pattern, "--dir", dir, "--clobber"),
          stdout = TRUE, stderr = TRUE))
        code <- as.integer(attr(st, "status") %||% 0L)
        if (identical(code, 0L)) return(0L)
        if (i < 3L) Sys.sleep(3 * i)
      }
      code
    },
    resolve_source = resolve_source,
    fetch_sources  = fetch_sources,
    now = function() Sys.time())
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  out_dir    <- if (length(args) >= 1) args[1] else "out"
  force_full <- tolower(Sys.getenv("BIOC_FORCE_REBUILD", "")) %in% c("true", "1", "yes")
  res <- run_update(default_io(), out_dir, force_full = force_full)
  cat("Changed shards:", if (length(res$changed_shards))
        paste(res$changed_shards, collapse = ", ") else "(none)", "\n")
}
