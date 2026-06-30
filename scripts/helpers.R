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
