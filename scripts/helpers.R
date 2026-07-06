# scripts/helpers.R: pure functions used by update.R, unit-tested in tests/testthat/.

`%||%` <- function(a, b) if (is.null(a)) b else a

# The four Bioconductor stat categories. The (dir, prefix) pair is hardcoded
# because the file prefix is not derivable from the dir: data-annotation uses the
# "annotation_" prefix and data-experiment uses "experiment_".
category_tuples <- function() {
  list(
    list(dir = "bioc",            prefix = "bioc_",       label = "software"),
    list(dir = "data-annotation", prefix = "annotation_", label = "data-annotation"),
    list(dir = "data-experiment", prefix = "experiment_", label = "data-experiment"),
    list(dir = "workflows",       prefix = "workflows_",  label = "workflows")
  )
}

# Aggregate "all packages, all months" file path for a category tuple.
category_file <- function(ct) sprintf("%s/%spkg_stats.tab", ct$dir, ct$prefix)

# Parse the 5-column aggregate stats TSV text into a tidy long data frame. Columns
# are addressed by header name (Package, Year, Month, Nb_of_distinct_IPs,
# Nb_of_downloads) so a future column reorder upstream cannot silently misalign.
parse_stats_tab <- function(text, category) {
  con <- textConnection(text)
  on.exit(close(con))
  df <- utils::read.delim(con, sep = "\t", header = TRUE,
                          colClasses = "character", check.names = FALSE,
                          quote = "", na.strings = character(0))
  data.frame(
    package        = df$Package,
    category       = category,
    year           = as.integer(df$Year),
    month_token    = df$Month,
    n_distinct_ips = as.integer(df$Nb_of_distinct_IPs),
    n_downloads    = as.integer(df$Nb_of_downloads),
    stringsAsFactors = FALSE)
}

# Map a month abbreviation (Jan..Dec) and year to a first-of-month ISO date.
month_to_date <- function(year, token) {
  mi <- match(token, month.abb)
  sprintf("%04d-%02d-01", as.integer(year), mi)
}

# Split a parsed stats frame into monthly rows (Month in Jan..Dec, dated to the
# first of the month) and yearly rows (the literal Month == "all" aggregate). The
# yearly distinct-IP value is non-additive, so it is carried verbatim from the
# "all" row, never recomputed from the months.
split_monthly_yearly <- function(df) {
  is_all <- df$month_token == "all"
  mdf <- df[!is_all, , drop = FALSE]
  ydf <- df[is_all, , drop = FALSE]
  monthly <- data.frame(
    package        = mdf$package,
    category       = mdf$category,
    date           = month_to_date(mdf$year, mdf$month_token),
    n_distinct_ips = mdf$n_distinct_ips,
    n_downloads    = mdf$n_downloads,
    stringsAsFactors = FALSE)
  yearly <- data.frame(
    package             = ydf$package,
    category            = ydf$category,
    year                = ydf$year,
    n_distinct_ips_year = ydf$n_distinct_ips,
    n_downloads_year    = ydf$n_downloads,
    stringsAsFactors = FALSE)
  list(monthly = monthly, yearly = yearly)
}

# Drop not-yet-happened future months: the current-year source pre-lists all 12
# months, so months after the latest real-data month appear as explicit zeros.
# Remove all-zero rows dated strictly after the latest non-zero month; keep
# genuine past zeros (a month that really had no downloads).
drop_future_placeholders <- function(monthly) {
  if (nrow(monthly) == 0) return(monthly)
  nz <- monthly$n_downloads > 0 | monthly$n_distinct_ips > 0
  if (!any(nz)) return(monthly[0, , drop = FALSE])
  latest <- max(monthly$date[nz])
  keep <- !(monthly$n_downloads == 0 & monthly$n_distinct_ips == 0 &
            monthly$date > latest)
  monthly[keep, , drop = FALSE]
}

# The anchor for all summary windows: the latest complete month. With no
# capture_month it is simply the latest month present. When capture_month (the
# in-progress month for this source, "YYYY-MM") is given, it is the latest month
# strictly before that, so a partial current month is never the anchor. The
# source's latest present month is typically the partial month being accumulated.
anchor_month <- function(monthly, capture_month = NA_character_) {
  if (nrow(monthly) == 0) return(NA_character_)
  d <- monthly$date
  if (!is.na(capture_month)) d <- d[substr(d, 1, 7) < capture_month]
  if (length(d) == 0) return(NA_character_)
  max(d)
}

# Write monthly (and optionally yearly) rows to a fresh SQLite shard. Overwrites
# any existing file, uses the published-shard PRAGMA (no WAL), and VACUUMs. The
# yearly table is created only when yearly rows are supplied, so the recent shard
# (monthly + summary only) can reuse this function with yearly = NULL.
export_shard <- function(path, monthly, yearly = NULL) {
  if (file.exists(path)) unlink(path)
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  DBI::dbExecute(con, "PRAGMA journal_mode=DELETE")
  DBI::dbExecute(con, "
    CREATE TABLE bioc_downloads_monthly (
      package        TEXT    NOT NULL,
      category       TEXT    NOT NULL,
      date           TEXT    NOT NULL,
      n_distinct_ips INTEGER NOT NULL,
      n_downloads    INTEGER NOT NULL,
      PRIMARY KEY (package, category, date))")
  DBI::dbExecute(con, "CREATE INDEX idx_bdm_date ON bioc_downloads_monthly(date)")
  DBI::dbExecute(con, "CREATE INDEX idx_bdm_pkg  ON bioc_downloads_monthly(package)")
  if (nrow(monthly) > 0) {
    DBI::dbWriteTable(con, "bioc_downloads_monthly",
      monthly[c("package", "category", "date", "n_distinct_ips", "n_downloads")],
      append = TRUE)
  }

  if (!is.null(yearly) && nrow(yearly) > 0) {
    DBI::dbExecute(con, "
      CREATE TABLE bioc_downloads_yearly (
        package             TEXT    NOT NULL,
        category            TEXT    NOT NULL,
        year                INTEGER NOT NULL,
        n_distinct_ips_year INTEGER,
        n_downloads_year    INTEGER,
        PRIMARY KEY (package, category, year))")
    DBI::dbWriteTable(con, "bioc_downloads_yearly",
      yearly[c("package", "category", "year", "n_distinct_ips_year", "n_downloads_year")],
      append = TRUE)
  }

  DBI::dbExecute(con, "VACUUM")
  invisible(NULL)
}

# The trailing N-month window of monthly rows, anchored to anchor_month (the
# latest data month), NOT today, because the source lags. months = 36 spans
# anchor and the 35 months before it.
extract_recent_monthly <- function(con, anchor_month, months = 36L) {
  a <- format(as.Date(anchor_month), "%Y-%m-%d")
  DBI::dbGetQuery(con, sprintf("
    SELECT package, category, date, n_distinct_ips, n_downloads
      FROM bioc_downloads_monthly
     WHERE date >= date('%s','-%d months') AND date <= '%s'
     ORDER BY package, category, date", a, as.integer(months) - 1L, a))
}

# Per-package summary over bioc_downloads_monthly, restricted to the trailing 12
# complete months ending at anchor_month. download_score is the Bioconductor
# headline: the average of monthly distinct IPs over those 12 months (sum / 12,
# an average of monthly figures, NOT a deduplicated total). Ranks are computed
# WITHIN each category (annotation traffic dwarfs software, so a global rank would
# be misleading and unlike Bioconductor's own per-category scores). trend compares
# the last 3 months of downloads to the prior 3, NULL when the prior window is 0.
summary_sql <- function(anchor_month) {
  a <- format(as.Date(anchor_month), "%Y-%m-%d")
  sprintf("
    WITH agg AS (
      SELECT package, category, LOWER(package) AS package_lower,
        ROUND(SUM(n_distinct_ips) / 12.0, 2) AS download_score,
        SUM(CASE WHEN date = '%1$s' THEN n_downloads ELSE 0 END) AS total_last_month,
        SUM(n_downloads) AS total_12mo,
        SUM(CASE WHEN date >= date('%1$s','-2 months') THEN n_downloads ELSE 0 END) AS last_3mo,
        SUM(CASE WHEN date >= date('%1$s','-5 months')
                  AND date <= date('%1$s','-3 months') THEN n_downloads ELSE 0 END) AS prev_3mo
      FROM bioc_downloads_monthly
      WHERE date >= date('%1$s','-11 months') AND date <= '%1$s'
      GROUP BY package, category)
    SELECT package, package_lower, category, download_score,
           total_last_month, total_12mo,
           RANK() OVER (PARTITION BY category ORDER BY download_score DESC) AS rank_score,
           RANK() OVER (PARTITION BY category ORDER BY total_12mo     DESC) AS rank_downloads_12mo,
           CASE WHEN prev_3mo > 0
                THEN ROUND((last_3mo * 1.0 / prev_3mo - 1.0) * 100.0, 2)
                ELSE NULL END AS trend
      FROM agg", a)
}

# Write a minimal SQLite file containing only the summary table (for the merger).
export_summary_shard <- function(path, summary) {
  if (file.exists(path)) unlink(path)
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbExecute(con, "PRAGMA journal_mode=DELETE")
  DBI::dbExecute(con, "
    CREATE TABLE bioc_downloads_summary (
      package             TEXT,
      package_lower       TEXT,
      category            TEXT,
      download_score      REAL,
      total_last_month    INTEGER,
      total_12mo          INTEGER,
      rank_score          INTEGER,
      rank_downloads_12mo INTEGER,
      trend               REAL,
      PRIMARY KEY (package, category))")
  if (nrow(summary) > 0) {
    DBI::dbWriteTable(con, "bioc_downloads_summary", summary, append = TRUE)
  }
  DBI::dbExecute(con, "VACUUM")
  invisible(NULL)
}

# Which source files changed since the last run (added, modified, deleted)? Maps
# are keyed by category file path; each value has a $hash identity (an HTTP ETag
# or Last-Modified for the live source, or the pinned snapshot id for Wayback).
diff_source_state <- function(prev_map, curr_map) {
  added    <- setdiff(names(curr_map), names(prev_map))
  deleted  <- setdiff(names(prev_map), names(curr_map))
  common   <- intersect(names(prev_map), names(curr_map))
  modified <- common[vapply(common,
    function(n) !identical(prev_map[[n]]$hash, curr_map[[n]]$hash), logical(1))]
  sort(unique(c(added, modified, deleted)))
}

# Carry forward the per-shard coverage map, overwriting rebuilt shards. prev may
# be NULL (cold start).
merge_shard_coverage <- function(prev, updates) {
  out <- prev %||% list()
  for (k in names(updates)) out[[k]] <- updates[[k]]
  out
}

# Write the manifest object as pretty JSON, preserving nulls and empty arrays.
write_manifest <- function(path, obj) {
  writeLines(
    jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE, null = "null"),
    path)
}

# Canonical live URL for a category's aggregate file under a base such as
# "https://bioconductor.org/packages/stats/".
live_url <- function(base, ct) paste0(base, category_file(ct))

# Internet Archive raw ("id_") snapshot URL for a category's canonical file.
wayback_raw_url <- function(ts, ct) {
  paste0("http://web.archive.org/web/", ts, "id_/",
         "https://bioconductor.org/packages/stats/", category_file(ct))
}

# Render the GitHub release body (markdown) from a manifest object, so the release
# page is self-describing (freshness, source, what changed, per-shard coverage).
write_release_notes <- function(path, manifest) {
  ts <- function(s) if (is.null(s) || is.na(s)) "n/a" else sub("Z$", " UTC", sub("T", " ", s))
  big <- function(x) if (is.null(x) || length(x) == 0 || is.na(x)) "0" else
    formatC(as.numeric(x), format = "d", big.mark = ",")
  cs <- manifest$changed_shards
  changed <- if (length(cs) == 0) "none (no source change since last run)" else
    paste(unlist(cs), collapse = ", ")
  dthrough <- manifest$data_through$monthly %||% "n/a"

  lines <- c(
    "Aggregated Bioconductor package download statistics, sourced from the Bioconductor download-stats `.tab` files. Counts are monthly, version-agnostic, and report both distinct IPs and downloads; they are not comparable to CRAN cranlogs or r2u counts. See the [README](https://github.com/r-observatory/bioconductor-downloads#readme) for the full caveats.",
    "",
    "This is a single rolling release. Assets are SQLite shards: per-year archives (`bioconductor-YYYY.db`), a rolling 36-month window (`bioconductor-recent.db`), and a summary-only file (`bioconductor-summary.db`), alongside `manifest.json`. Each run replaces only the shards that changed.",
    "",
    "| | |",
    "|---|---|",
    sprintf("| **Last checked** | %s |", ts(manifest$last_checked)),
    sprintf("| **Source this run** | %s |", manifest$source_kind %||% "n/a"),
    sprintf("| **Data through** | %s |", dthrough),
    sprintf("| **Changed this run** | %s |", changed),
    "",
    "## Shard coverage",
    "",
    "| Shard | Rows | From | To |",
    "|---|---:|---|---|")
  shards <- manifest$shards %||% list()
  for (nm in sort(names(shards))) {
    s <- shards[[nm]]
    lines <- c(lines, sprintf("| `%s` | %s | %s | %s |",
      nm, big(s$rows), s$date_min %||% "n/a", s$date_max %||% "n/a"))
  }
  lines <- c(lines, "",
    "_Fetch the rolling 36-month window:_",
    "```bash",
    "gh release download current --repo r-observatory/bioconductor-downloads --pattern bioconductor-recent.db",
    "```")
  writeLines(lines, path)
  invisible(NULL)
}

# Extract the Package names from a Bioconductor VIEWS file (DCF text). Returns a
# sorted unique character vector.
parse_views_packages <- function(text) {
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  pk <- grep("^Package:[[:space:]]*", lines, value = TRUE)
  sort(unique(trimws(sub("^Package:[[:space:]]*", "", pk))))
}

# Extract package names from the Bioconductor removed-packages HTML page. Parse
# BOTH anchor hrefs (.../html/<name>.html) and bare <li><name></li> items, because
# some legacy entries appear only as bare list items. Returns sorted unique names.
parse_removed_packages <- function(html) {
  a <- regmatches(html, gregexpr(
    "/packages/[^/]+/[a-z/]+/html/[A-Za-z0-9._]+\\.html", html))[[1]]
  a_names <- sub(".*/html/([A-Za-z0-9._]+)\\.html$", "\\1", a)
  li <- regmatches(html, gregexpr("<li>[A-Za-z0-9._]+</li>", html))[[1]]
  li_names <- sub("^<li>([A-Za-z0-9._]+)</li>$", "\\1", li)
  sort(unique(c(a_names, li_names)))
}

# Tag each package name as "bioc" (present in the Bioconductor roster, including
# removed packages) or "cran" (a CRAN package seen only via the Bioconductor
# mirror). Exact case-sensitive membership; roster presence wins on collision.
classify_origin <- function(names, bioc_roster) {
  ifelse(names %in% bioc_roster, "bioc", "cran")
}
