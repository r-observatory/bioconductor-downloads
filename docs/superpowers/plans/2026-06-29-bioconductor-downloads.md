# bioconductor-downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a producer pipeline that turns Bioconductor's monthly per-package download statistics into year-sharded SQLite published on a rolling `current` GitHub release, bootstrapped from the Internet Archive during the 2026 stats outage and auto-flipping to the canonical endpoint when it returns.

**Architecture:** Pure, unit-tested helpers in `scripts/helpers.R` (TSV parse, monthly/yearly split, future-placeholder drop, SQLite shard export, summary SQL, change detection, manifest). An injectable-`io` orchestrator `run_update(io, out_dir)` in `scripts/update.R` resolves the live-or-Wayback source, change-gates, and on any change does a full rebuild (data is small). A daily GitHub Actions cron runs tests then the producer, and uploads only changed shards with `manifest.json` last.

**Tech Stack:** R (scripts, not a package), `DBI` + `RSQLite`, `jsonlite`, `curl`/`utils::download.file`, `testthat` 3e. No DuckDB. Mirrors the `r2u-downloads` and `cran-downloads` siblings.

## Global Constraints

- Repo name: `bioconductor-downloads`; publish repo `r-observatory/bioconductor-downloads`.
- Tables namespaced `bioc_`: `bioc_downloads_monthly`, `bioc_downloads_yearly`, `bioc_downloads_summary`.
- Package key is the **canonical Bioconductor case**; carry a lowercased `package_lower` helper column in the summary only.
- Four categories with hardcoded `(dir, prefix, label)` tuples: `("bioc","bioc_","software")`, `("data-annotation","annotation_","data-annotation")`, `("data-experiment","experiment_","data-experiment")`, `("workflows","workflows_","workflows")`. Aggregate file path is `<dir>/<prefix>pkg_stats.tab`.
- Aggregate TSV columns (read by header name, never by position): `Package`, `Year`, `Month`, `Nb_of_distinct_IPs`, `Nb_of_downloads`. `Month` is `Jan`..`Dec` or the literal `all`.
- `n_downloads` is additive across months; `n_distinct_ips` is NOT (take the `all` row for a yearly figure; never sum distinct IPs across periods).
- Monthly granularity only; `date` stored as first-of-month `YYYY-MM-01`. Reserve (do not build) a future `bioc_downloads_daily` table and `bioconductor-daily-YYYY.db` shard family.
- `download_score` = mean of monthly `n_distinct_ips` over the trailing 12 complete months ending at the anchor, i.e. `SUM(n_distinct_ips over 12 months) / 12.0`. The anchor is the latest complete month in the data (not "today").
- `RECENT_MONTHS = 36`. `trend` = percent change of the last 3 complete months of downloads vs the prior 3; `NULL` when the prior window is 0.
- Published shards: `PRAGMA journal_mode=DELETE`, then `VACUUM` at export.
- Style: markdown and prose docs use no em dashes and no hard-wrapped paragraphs. Source code (including comments) follows the r2u-downloads/cran-downloads house style, which wraps comments near 80 columns; keep all code free of em dashes. Commit messages use no em dashes and never reference a plan, spec, stage, or implementation notes.
- License: MIT for pipeline code.

## File Structure

- `scripts/helpers.R`: pure functions (Tasks 1-9).
- `scripts/config.R`: category tuples wrapper, candidate base URLs, Wayback snapshot pins, `RECENT_MONTHS` (Task 1, extended Task 10).
- `scripts/update.R`: impure IO helpers, `run_update()` orchestrator, `default_io()`, CLI entry (Tasks 10-11).
- `scripts/bootstrap-from-wayback.R`: one-shot full build entry point (Task 12).
- `tests/testthat.R`, `tests/testthat/helper-setup.R`: harness (Task 1).
- `tests/testthat/test-*.R`: one per helper plus the orchestrator integration test.
- `.github/workflows/update.yml`, `.github/workflows/test.yml` (Task 13).
- `README.md`, `LICENSE`, `.gitignore`, `last-updated.txt` (Task 13).

---

### Task 1: Test harness, config, and `category_tuples()`

**Files:**
- Create: `.gitignore`, `LICENSE`, `tests/testthat.R`, `tests/testthat/helper-setup.R`, `scripts/config.R`, `scripts/helpers.R`
- Test: `tests/testthat/test-categories.R`

**Interfaces:**
- Produces: `` `%||%`(a, b) ``; `category_tuples() -> list` of `list(dir, prefix, label)`; `category_file(ct) -> "<dir>/<prefix>pkg_stats.tab"`.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
*.db
*.tab
out/
tmp/
_src/
.Rhistory
.RData
.Rproj.user
```

- [ ] **Step 2: Create `LICENSE`** (MIT, copyright "James Balamuta and the r-observatory contributors"). Use the standard MIT text.

- [ ] **Step 3: Create the test harness**

`tests/testthat.R`:

```r
library(testthat)
test_dir(file.path("tests", "testthat"))
```

`tests/testthat/helper-setup.R`:

```r
# Auto-sourced by testthat before tests run. Sources the pipeline code so tests
# can call the helpers and the orchestrator directly. During test_dir() the
# working directory is tests/testthat, so the repo root is two levels up.
.bioc_root <- normalizePath(file.path(getwd(), "..", ".."))

source(file.path(.bioc_root, "scripts", "config.R"))
source(file.path(.bioc_root, "scripts", "helpers.R"))

.bioc_update <- file.path(.bioc_root, "scripts", "update.R")
if (file.exists(.bioc_update)) source(.bioc_update)

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
```

- [ ] **Step 4: Create `scripts/config.R`** (constants extended in Task 10)

```r
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
```

- [ ] **Step 5: Write the failing test** `tests/testthat/test-categories.R`

```r
test_that("category_tuples covers the four categories with the filename quirk", {
  cts <- category_tuples()
  expect_equal(length(cts), 4L)
  labels <- vapply(cts, function(x) x$label, character(1))
  expect_setequal(labels,
    c("software", "data-annotation", "data-experiment", "workflows"))

  by_label <- function(l) Filter(function(x) x$label == l, cts)[[1]]
  expect_equal(category_file(by_label("software")), "bioc/bioc_pkg_stats.tab")
  expect_equal(category_file(by_label("data-annotation")),
               "data-annotation/annotation_pkg_stats.tab")
  expect_equal(category_file(by_label("data-experiment")),
               "data-experiment/experiment_pkg_stats.tab")
  expect_equal(category_file(by_label("workflows")),
               "workflows/workflows_pkg_stats.tab")
})
```

- [ ] **Step 6: Run it, expect FAIL**: `Rscript tests/testthat.R` fails with `could not find function "category_tuples"`.

- [ ] **Step 7: Create `scripts/helpers.R` with the first functions**

```r
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
```

- [ ] **Step 8: Run it, expect PASS**: `Rscript tests/testthat.R`.

- [ ] **Step 9: Commit**

```bash
git add .gitignore LICENSE tests scripts
git commit -m "Add test harness, config, and Bioconductor category tuples"
```

---

### Task 2: `parse_stats_tab()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-parse-stats-tab.R`

**Interfaces:**
- Produces: `parse_stats_tab(text, category) -> data.frame(package, category, year:int, month_token, n_distinct_ips:int, n_downloads:int)`. Reads the 5-column aggregate TSV by header name.

- [ ] **Step 1: Write the failing test**

```r
test_that("parse_stats_tab reads the aggregate TSV by header, ignoring column order", {
  text <- paste(
    "Package\tYear\tMonth\tNb_of_distinct_IPs\tNb_of_downloads",
    "a4\t2026\tJan\t163\t239",
    "a4\t2026\tall\t163\t239",
    "DESeq2\t2025\tDec\t9000\t25000",
    sep = "\n")
  df <- parse_stats_tab(text, "software")
  expect_equal(nrow(df), 3L)
  expect_equal(df$package, c("a4", "a4", "DESeq2"))
  expect_equal(df$category, rep("software", 3L))
  expect_equal(df$year, c(2026L, 2026L, 2025L))
  expect_equal(df$month_token, c("Jan", "all", "Dec"))
  expect_equal(df$n_distinct_ips, c(163L, 163L, 9000L))
  expect_equal(df$n_downloads, c(239L, 239L, 25000L))
  expect_type(df$year, "integer")
})
```

- [ ] **Step 2: Run it, expect FAIL** (`could not find function "parse_stats_tab"`).

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-parse-stats-tab.R
git commit -m "Parse the Bioconductor aggregate stats TSV by header"
```

---

### Task 3: `month_to_date()` and `split_monthly_yearly()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-split-monthly-yearly.R`

**Interfaces:**
- Produces: `month_to_date(year, token) -> "YYYY-MM-01"` (vectorized, `token` in `Jan`..`Dec`); `split_monthly_yearly(df) -> list(monthly = data.frame(package, category, date, n_distinct_ips, n_downloads), yearly = data.frame(package, category, year, n_distinct_ips_year, n_downloads_year))`.

- [ ] **Step 1: Write the failing test**

```r
test_that("month_to_date maps month abbreviations to first-of-month ISO dates", {
  expect_equal(month_to_date(2025L, "Jan"), "2025-01-01")
  expect_equal(month_to_date(2026L, "Dec"), "2026-12-01")
  expect_equal(month_to_date(c(2025L, 2025L), c("Mar", "Nov")),
               c("2025-03-01", "2025-11-01"))
})

test_that("split_monthly_yearly separates 'all' rows into the yearly frame", {
  df <- parse_stats_tab(paste(
    "Package\tYear\tMonth\tNb_of_distinct_IPs\tNb_of_downloads",
    "a4\t2026\tJan\t163\t239",
    "a4\t2026\tall\t163\t239",
    "limma\t2024\tall\t276697\t756903",
    sep = "\n"), "software")
  sp <- split_monthly_yearly(df)

  expect_equal(nrow(sp$monthly), 1L)
  expect_equal(sp$monthly$date, "2026-01-01")
  expect_equal(sp$monthly$n_downloads, 239L)
  expect_false("month_token" %in% names(sp$monthly))

  expect_equal(nrow(sp$yearly), 2L)
  expect_setequal(sp$yearly$year, c(2026L, 2024L))
  lm <- sp$yearly[sp$yearly$package == "limma", ]
  expect_equal(lm$n_distinct_ips_year, 276697L)  # taken from the 'all' row, not summed
  expect_equal(lm$n_downloads_year, 756903L)
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-split-monthly-yearly.R
git commit -m "Split monthly rows from yearly 'all' rows"
```

---

### Task 4: `drop_future_placeholders()` and `anchor_month()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-drop-future-placeholders.R`

**Interfaces:**
- Produces: `drop_future_placeholders(monthly) -> monthly` (removes all-zero rows dated after the latest non-zero month; keeps genuine past zeros); `anchor_month(monthly, capture_month = NA_character_) -> "YYYY-MM-01"` or `NA_character_` (the latest complete month: the latest present month, or the latest strictly before `capture_month` when given, so a partial in-progress month is never the anchor).

- [ ] **Step 1: Write the failing test**

```r
# mk_monthly() is provided by tests/testthat/helper-setup.R (Task 1).
test_that("drop_future_placeholders drops trailing all-zero months but keeps past zeros", {
  m <- mk_monthly(
    date = c("2026-01-01", "2025-07-01", "2026-02-01", "2026-12-01"),
    ips  = c(163L,          0L,           0L,            0L),
    dl   = c(239L,          0L,           0L,            0L))
  out <- drop_future_placeholders(m)
  # 2026-01 is the latest non-zero month. 2025-07 (past zero) is kept;
  # 2026-02 and 2026-12 (future zeros) are dropped.
  expect_setequal(out$date, c("2026-01-01", "2025-07-01"))
})

test_that("anchor_month is the latest present month, or the latest before the capture month", {
  m <- mk_monthly(c("2026-01-01", "2025-12-01", "2025-07-01"),
                  c(163L, 9L, 5L), c(239L, 9L, 5L))
  expect_equal(anchor_month(m), "2026-01-01")            # no capture month -> latest present
  expect_equal(anchor_month(m, "2026-01"), "2025-12-01") # exclude the partial Jan 2026
  expect_true(is.na(anchor_month(m[0, , drop = FALSE])))
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-drop-future-placeholders.R
git commit -m "Drop future-month zero placeholders, keep past zeros"
```

---

### Task 5: `export_shard()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-export-shard.R`

**Interfaces:**
- Produces: `export_shard(path, monthly, yearly = NULL)` writes a fresh SQLite file with `bioc_downloads_monthly` (always) and `bioc_downloads_yearly` (only when `yearly` is non-empty), `PRAGMA journal_mode=DELETE`, indices on `date` and `package`, then `VACUUM`.

- [ ] **Step 1: Write the failing test**

```r
test_that("export_shard writes the monthly and yearly tables with the right schema", {
  d <- withr::local_tempdir()
  path <- file.path(d, "bioconductor-2025.db")
  monthly <- data.frame(
    package = c("limma", "limma"), category = "software",
    date = c("2025-11-01", "2025-12-01"),
    n_distinct_ips = c(20000L, 21000L), n_downloads = c(60000L, 63000L),
    stringsAsFactors = FALSE)
  yearly <- data.frame(
    package = "limma", category = "software", year = 2025L,
    n_distinct_ips_year = 276697L, n_downloads_year = 756903L,
    stringsAsFactors = FALSE)

  export_shard(path, monthly, yearly)

  con <- DBI::dbConnect(RSQLite::SQLite(), path); on.exit(DBI::dbDisconnect(con))
  expect_setequal(DBI::dbListTables(con),
                  c("bioc_downloads_monthly", "bioc_downloads_yearly"))
  m <- DBI::dbGetQuery(con, "SELECT * FROM bioc_downloads_monthly ORDER BY date")
  expect_equal(m$n_downloads, c(60000L, 63000L))
  y <- DBI::dbGetQuery(con, "SELECT * FROM bioc_downloads_yearly")
  expect_equal(y$n_distinct_ips_year, 276697L)
})

test_that("export_shard omits the yearly table when yearly is NULL (recent.db case)", {
  d <- withr::local_tempdir()
  path <- file.path(d, "bioconductor-recent.db")
  monthly <- data.frame(package = "limma", category = "software",
    date = "2025-12-01", n_distinct_ips = 21000L, n_downloads = 63000L,
    stringsAsFactors = FALSE)
  export_shard(path, monthly)
  con <- DBI::dbConnect(RSQLite::SQLite(), path); on.exit(DBI::dbDisconnect(con))
  expect_equal(DBI::dbListTables(con), "bioc_downloads_monthly")
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-export-shard.R
git commit -m "Export year shards with monthly and yearly tables"
```

---

### Task 6: `extract_recent_monthly()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-extract-recent.R`

**Interfaces:**
- Consumes: a SQLite connection holding `bioc_downloads_monthly`.
- Produces: `extract_recent_monthly(con, anchor_month, months = 36L) -> data.frame(package, category, date, n_distinct_ips, n_downloads)` for the trailing `months` ending at `anchor_month`.

- [ ] **Step 1: Write the failing test**

```r
# mk_con() is provided by tests/testthat/helper-setup.R (Task 1).
test_that("extract_recent_monthly returns only the trailing window ending at the anchor", {
  rows <- data.frame(
    package = "p", category = "software",
    date = c("2023-01-01", "2024-01-01", "2025-12-01", "2026-01-01"),
    n_distinct_ips = 1L, n_downloads = 1L, stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))
  rec <- extract_recent_monthly(con, "2026-01-01", months = 36L)  # cutoff 2023-02-01
  expect_setequal(rec$date, c("2024-01-01", "2025-12-01", "2026-01-01"))
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-extract-recent.R
git commit -m "Extract the trailing monthly window for the recent shard"
```

---

### Task 7: `summary_sql()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-summary.R`

**Interfaces:**
- Produces: `summary_sql(anchor_month) -> character(1)` SQL over `bioc_downloads_monthly` returning columns `package, package_lower, category, download_score, total_last_month, total_12mo, rank_score, rank_downloads_12mo, trend`.

- [ ] **Step 1: Write the failing test**

```r
test_that("summary computes the download score, totals, ranks, and trend", {
  # One package, 12 months of 2025, distinct IPs = 10 each -> score = 120/12 = 10.
  months <- sprintf("2025-%02d-01", 1:12)
  rows <- data.frame(
    package = "limma", category = "software", date = months,
    n_distinct_ips = rep(10L, 12),
    n_downloads = rep(100L, 12), stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))

  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  expect_equal(s$package, "limma")
  expect_equal(s$package_lower, "limma")
  expect_equal(s$category, "software")
  expect_equal(s$download_score, 10.0)
  expect_equal(s$total_last_month, 100L)   # December
  expect_equal(s$total_12mo, 1200L)
  expect_equal(s$rank_score, 1L)
  # last 3 months (Oct+Nov+Dec)=300 vs prior 3 (Jul+Aug+Sep)=300 -> 0% trend
  expect_equal(s$trend, 0.0)
})

test_that("trend is NULL when the prior 3-month window is empty", {
  rows <- data.frame(package = "p", category = "software",
    date = c("2025-11-01", "2025-12-01"),
    n_distinct_ips = c(5L, 5L), n_downloads = c(50L, 50L),
    stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))
  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  expect_true(is.na(s$trend))
})

test_that("download_score divides by 12 even when fewer months are present", {
  rows <- data.frame(package = "p", category = "software",
    date = c("2025-11-01", "2025-12-01"),
    n_distinct_ips = c(6L, 6L), n_downloads = c(1L, 1L),
    stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))
  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  expect_equal(s$download_score, round((6 + 6) / 12.0, 2))  # = 1.0
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-summary.R
git commit -m "Build the per-package summary with the official download score"
```

---

### Task 8: `export_summary_shard()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-export-summary.R`

**Interfaces:**
- Consumes: a `summary` data.frame whose columns are `SUMMARY_COLS` (defined in Task 11): `package, package_lower, category, download_score, total_last_month, total_12mo, rank_score, rank_downloads_12mo, trend`.
- Produces: `export_summary_shard(path, summary)` writes a fresh SQLite file with only `bioc_downloads_summary`.

- [ ] **Step 1: Write the failing test**

```r
test_that("export_summary_shard writes only the summary table", {
  d <- withr::local_tempdir(); path <- file.path(d, "bioconductor-summary.db")
  summary <- data.frame(
    package = "limma", package_lower = "limma", category = "software",
    download_score = 10.0, total_last_month = 100L, total_12mo = 1200L,
    rank_score = 1L, rank_downloads_12mo = 1L, trend = 0.0,
    stringsAsFactors = FALSE)
  export_summary_shard(path, summary)
  con <- DBI::dbConnect(RSQLite::SQLite(), path); on.exit(DBI::dbDisconnect(con))
  expect_equal(DBI::dbListTables(con), "bioc_downloads_summary")
  got <- DBI::dbGetQuery(con, "SELECT * FROM bioc_downloads_summary")
  expect_equal(got$download_score, 10.0)
  expect_equal(got$package_lower, "limma")
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-export-summary.R
git commit -m "Export the summary-only shard for the data merger"
```

---

### Task 9: `diff_source_state()`, `merge_shard_coverage()`, `write_manifest()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-manifest.R`

**Interfaces:**
- Produces: `diff_source_state(prev_map, curr_map) -> sorted unique changed paths` (compares each entry's `$hash`); `merge_shard_coverage(prev, updates) -> list`; `write_manifest(path, obj)` writes pretty JSON preserving nulls.

- [ ] **Step 1: Write the failing test**

```r
test_that("diff_source_state reports added, modified, and deleted by hash", {
  prev <- list("bioc/bioc_pkg_stats.tab" = list(hash = "A"),
               "workflows/workflows_pkg_stats.tab" = list(hash = "W"))
  curr <- list("bioc/bioc_pkg_stats.tab" = list(hash = "B"),         # modified
               "data-experiment/experiment_pkg_stats.tab" = list(hash = "E"))  # added
  expect_equal(diff_source_state(prev, curr),
    sort(c("bioc/bioc_pkg_stats.tab",
           "data-experiment/experiment_pkg_stats.tab",
           "workflows/workflows_pkg_stats.tab")))  # last is deleted
})

test_that("diff_source_state is empty when hashes are unchanged", {
  m <- list("bioc/bioc_pkg_stats.tab" = list(hash = "A"))
  expect_length(diff_source_state(m, m), 0L)
})

test_that("merge_shard_coverage overwrites only updated shards", {
  prev <- list("bioconductor-2009.db" = list(rows = 1L),
               "bioconductor-2026.db" = list(rows = 2L))
  upd  <- list("bioconductor-2026.db" = list(rows = 9L))
  out  <- merge_shard_coverage(prev, upd)
  expect_equal(out[["bioconductor-2009.db"]]$rows, 1L)
  expect_equal(out[["bioconductor-2026.db"]]$rows, 9L)
})

test_that("write_manifest round-trips and preserves null trend", {
  d <- withr::local_tempdir(); p <- file.path(d, "manifest.json")
  obj <- list(source_kind = "wayback", granularities = list("monthly"),
              data_through = list(monthly = "2026-01"))
  write_manifest(p, obj)
  back <- jsonlite::fromJSON(p, simplifyVector = FALSE)
  expect_equal(back$source_kind, "wayback")
  expect_equal(back$data_through$monthly, "2026-01")
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-manifest.R
git commit -m "Add source-state diff, coverage merge, and manifest writer"
```

---

### Task 10: URL builders and `write_release_notes()`

**Files:**
- Modify: `scripts/helpers.R`
- Test: `tests/testthat/test-urls.R`

**Interfaces:**
- Produces: `live_url(base, ct) -> character(1)`; `wayback_raw_url(ts, ct) -> character(1)`; `write_release_notes(path, manifest)`.

- [ ] **Step 1: Write the failing test**

```r
test_that("live_url and wayback_raw_url build the canonical category paths", {
  ct <- list(dir = "data-annotation", prefix = "annotation_", label = "data-annotation")
  expect_equal(
    live_url("https://bioconductor.org/packages/stats/", ct),
    "https://bioconductor.org/packages/stats/data-annotation/annotation_pkg_stats.tab")
  expect_equal(
    wayback_raw_url("20260126211628", ct),
    paste0("http://web.archive.org/web/20260126211628id_/",
           "https://bioconductor.org/packages/stats/data-annotation/annotation_pkg_stats.tab"))
})

test_that("write_release_notes renders a self-describing body", {
  d <- withr::local_tempdir(); p <- file.path(d, "release_notes.md")
  manifest <- list(last_checked = "2026-06-29T06:00:00Z", source_kind = "wayback",
    data_through = list(monthly = "2026-01"), changed_shards = list("bioconductor-2026.db"),
    shards = list("bioconductor-2026.db" =
      list(rows = 10L, date_min = "2026-01-01", date_max = "2026-01-01")))
  write_release_notes(p, manifest)
  txt <- paste(readLines(p), collapse = "\n")
  expect_true(grepl("wayback", txt))
  expect_true(grepl("2026-01", txt))
  expect_true(grepl("bioconductor-2026.db", txt))
})
```

- [ ] **Step 2: Run it, expect FAIL.**

- [ ] **Step 3: Implement** (append to `scripts/helpers.R`)

```r
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
```

- [ ] **Step 4: Run it, expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/helpers.R tests/testthat/test-urls.R
git commit -m "Add live and Wayback URL builders and release notes"
```

---

### Task 11: `run_update()` orchestrator (integration-tested with a fake io)

**Files:**
- Create: `scripts/update.R`
- Test: `tests/testthat/test-run-update.R`

**Interfaces:**
- Consumes: every helper above; `RECENT_MONTHS`, `CANDIDATE_BASE_URLS` from config.
- Produces: `run_update(io, out_dir, force_full = FALSE) -> list(changed_shards, manifest)`. The `io` list provides: `release_exists() -> logical`; `release_download(pattern, dir) -> int`; `resolve_source() -> list(kind in c("live","wayback","none"), source_files = named map path -> list(hash, etag, last_modified, via), capture_month = "YYYY-MM" or NULL)` where `capture_month` is the in-progress month to exclude from the anchor; `fetch_sources(paths, dir) -> named character (path -> local file)`; `now() -> POSIXct`. Also produces `SUMMARY_COLS` and the impure helpers `init_monthly`, `load_monthly`, `embed_summary`, `coverage`, `empty_monthly`, `empty_yearly`, `iso`.

- [ ] **Step 1: Write the failing integration test**

```r
# A fake io backed by local fixture .tab files, exercising the wayback path.
fake_io <- function(tmp, now = as.POSIXct("2026-06-29 06:00:00", tz = "UTC")) {
  cts <- category_tuples()
  # Write one tiny aggregate file per category into tmp/src.
  src <- file.path(tmp, "src"); dir.create(src, recursive = TRUE, showWarnings = FALSE)
  files <- list()
  for (ct in cts) {
    body <- paste(
      "Package\tYear\tMonth\tNb_of_distinct_IPs\tNb_of_downloads",
      "pkgA\t2025\tNov\t10\t100",
      "pkgA\t2025\tDec\t12\t120",
      "pkgA\t2025\tall\t20\t220",
      "pkgA\t2026\tJan\t5\t40",
      "pkgA\t2026\tFeb\t0\t0",     # future placeholder, must be dropped
      "pkgA\t2026\tall\t5\t40",
      sep = "\n")
    f <- file.path(src, gsub("/", "_", category_file(ct)))
    writeLines(body, f)
    files[[category_file(ct)]] <- f
  }
  list(
    release_exists   = function() FALSE,
    release_download = function(pattern, dir) 1L,
    resolve_source   = function() list(
      kind = "wayback",
      capture_month = "2026-02",   # the in-progress month for this snapshot
      source_files = stats::setNames(
        lapply(names(files), function(p) list(hash = "snap1", via = "wayback:snap1")),
        names(files))),
    fetch_sources    = function(paths, dir) stats::setNames(unlist(files[paths]), paths),
    now              = function() now)
}

test_that("run_update bootstraps shards, recent, summary, and manifest from source", {
  tmp <- withr::local_tempdir(); out <- file.path(tmp, "out")
  res <- run_update(fake_io(tmp), out)

  expect_true(file.exists(file.path(out, "bioconductor-2025.db")))
  expect_true(file.exists(file.path(out, "bioconductor-2026.db")))
  expect_true(file.exists(file.path(out, "bioconductor-recent.db")))
  expect_true(file.exists(file.path(out, "bioconductor-summary.db")))
  expect_true(file.exists(file.path(out, "manifest.json")))

  con <- DBI::dbConnect(RSQLite::SQLite(), file.path(out, "bioconductor-2026.db"))
  on.exit(DBI::dbDisconnect(con))
  m <- DBI::dbGetQuery(con, "SELECT * FROM bioc_downloads_monthly ORDER BY date")
  # 2026-02 future placeholder dropped, only 2026-01 remains per category.
  expect_equal(unique(m$date), "2026-01-01")
  expect_equal(length(unique(m$category)), 4L)

  man <- jsonlite::fromJSON(file.path(out, "manifest.json"), simplifyVector = FALSE)
  expect_equal(man$source_kind, "wayback")
  expect_equal(man$granularities[[1]], "monthly")
  expect_equal(man$data_through$monthly, "2026-01")
  expect_true("bioconductor-summary.db" %in% unlist(man$changed_shards))
})

test_that("run_update heartbeats when nothing changed", {
  tmp <- withr::local_tempdir(); out <- file.path(tmp, "out")
  io <- fake_io(tmp)
  run_update(io, out)                       # first run builds
  res2 <- run_update(io, out)               # second run: same hashes -> heartbeat
  expect_length(res2$changed_shards, 0L)
  man <- jsonlite::fromJSON(file.path(out, "manifest.json"), simplifyVector = FALSE)
  expect_equal(length(man$changed_shards), 0L)
})
```

> Note: the heartbeat test relies on `run_update` reading the manifest it wrote in `out/`. Because `release_exists()` is `FALSE` in the fake io, the orchestrator reads `out/manifest.json` directly when present. Keep that behavior: when the release does not exist but a local `manifest.json` is already in `out_dir`, load it as `prev`.

- [ ] **Step 2: Run it, expect FAIL** (`could not find function "run_update"`).

- [ ] **Step 3: Implement `scripts/update.R`**

```r
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
```

- [ ] **Step 4: Run it, expect PASS**: `Rscript tests/testthat.R`.

- [ ] **Step 5: Commit**

```bash
git add scripts/update.R tests/testthat/test-run-update.R
git commit -m "Add the change-gated producer orchestrator"
```

---

### Task 12: `default_io()`, CLI entry, and the Wayback bootstrap script

**Files:**
- Modify: `scripts/update.R`
- Create: `scripts/bootstrap-from-wayback.R`
- Test: `tests/testthat/test-default-io.R` (pure parts only)

**Interfaces:**
- Produces: `default_io() -> io list` (production gh + HTTP IO); CLI entry under `if (sys.nframe() == 0L)`.

- [ ] **Step 1: Write the failing test** (only the pure URL wiring, no network)

```r
test_that("default_io resolve order prefers the canonical base then Wayback", {
  # resolve_source is network-driven, so we test the pure URL builders it uses.
  ct <- category_tuples()[[1]]  # software
  expect_equal(live_url(CANDIDATE_BASE_URLS[1], ct),
               "https://bioconductor.org/packages/stats/bioc/bioc_pkg_stats.tab")
  expect_match(wayback_raw_url(WAYBACK_SNAPSHOTS[["bioc"]], ct), "^http://web.archive.org/web/")
})
```

- [ ] **Step 2: Run it, expect FAIL** if `CANDIDATE_BASE_URLS`/`WAYBACK_SNAPSHOTS` are not visible to the test (they are sourced via config.R in helper-setup). If config is already loaded this passes immediately after Step 3 adds nothing; in that case add the `default_io` body in Step 3 and keep this as a regression guard.

- [ ] **Step 3: Implement `default_io()` and CLI** (append to `scripts/update.R`)

```r
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
```

- [ ] **Step 4: Create `scripts/bootstrap-from-wayback.R`**

```r
#!/usr/bin/env Rscript
# scripts/bootstrap-from-wayback.R: explicit one-shot full build from the pinned
# Internet Archive snapshots, used while the canonical endpoint is in outage.
# Equivalent to update.R against an empty release with force_full = TRUE.
.dir <- dirname(sub("^--file=", "", grep("^--file=",
  commandArgs(FALSE), value = TRUE))[1])
source(file.path(.dir, "config.R"))
source(file.path(.dir, "helpers.R"))
source(file.path(.dir, "update.R"))

out_dir <- { a <- commandArgs(trailingOnly = TRUE); if (length(a) >= 1) a[1] else "out" }
res <- run_update(default_io(), out_dir, force_full = TRUE)
cat("Bootstrapped shards:", paste(res$changed_shards, collapse = ", "), "\n")
```

- [ ] **Step 5: Run the suite, expect PASS, then commit**

```bash
Rscript tests/testthat.R
git add scripts/update.R scripts/bootstrap-from-wayback.R tests/testthat/test-default-io.R
git commit -m "Add production IO, CLI entry, and the Wayback bootstrap"
```

- [ ] **Step 6: Confirm the live Wayback snapshot pins** by fetching the per-category aggregate via `wayback_raw_url()` for each `dir`, checking the latest non-`all` month present, and updating `WAYBACK_SNAPSHOTS` in `scripts/config.R` to the freshest good snapshot per category. Commit any pin change with message `Pin freshest Wayback snapshots per category`.

---

### Task 13: Workflows, README, and first bootstrap run

**Files:**
- Create: `.github/workflows/update.yml`, `.github/workflows/test.yml`, `README.md`, `last-updated.txt`

**Interfaces:** none (delivery).

- [ ] **Step 1: Create `.github/workflows/test.yml`**

```yaml
name: Test

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
        with:
          r-version: "release"
          use-public-rspm: true
      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          packages: |
            any::RSQLite
            any::DBI
            any::jsonlite
            any::curl
            any::testthat
            any::withr
      - name: Run unit tests
        run: Rscript tests/testthat.R
```

- [ ] **Step 2: Create `.github/workflows/update.yml`**

```yaml
name: Update Bioconductor Downloads

on:
  schedule:
    # Daily at 06:00 UTC, ahead of the r-observatory/data merge (~08:00 UTC).
    # Most runs are cheap no-ops: the source changes about twice a week, and
    # during the stats outage the pinned Wayback source never changes, so a run
    # only rebuilds when a source file's content identity changes.
    - cron: "0 6 * * *"
  workflow_dispatch:
    inputs:
      force_full_rebuild:
        description: "Rebuild every shard from the current source, ignoring the prior manifest."
        type: boolean
        default: false

permissions:
  contents: write

concurrency:
  group: bioconductor-downloads-update
  cancel-in-progress: false

jobs:
  update:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - uses: r-lib/actions/setup-r@v2
        with:
          r-version: "release"
          use-public-rspm: true
      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          packages: |
            any::RSQLite
            any::DBI
            any::jsonlite
            any::curl
            any::testthat
            any::withr
      - name: Run unit tests
        run: Rscript tests/testthat.R
      - name: Run update script
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          BIOC_FORCE_REBUILD: ${{ inputs.force_full_rebuild }}
        run: |
          mkdir -p out
          Rscript scripts/update.R out/
      - name: Publish changed shards to "current" release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          if ! gh release view current >/dev/null 2>&1; then
            git tag -f current
            git push -f origin current || true
            gh release create current \
              --title "Bioconductor Downloads (rolling)" \
              --notes-file out/release_notes.md \
              --latest
          fi
          CHANGED=$(jq -r '.changed_shards[]' out/manifest.json)
          for asset in $CHANGED; do
            if [ -f "out/$asset" ]; then
              gh release upload current "out/$asset" --clobber
            else
              echo "WARNING: $asset listed in manifest but not on disk"
            fi
          done
          gh release upload current out/manifest.json --clobber
          gh release edit current --notes-file out/release_notes.md
      - name: Update last run timestamp
        continue-on-error: true
        run: |
          echo "Last updated: $(date -u +'%Y-%m-%d %H:%M:%S UTC')" > last-updated.txt
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add last-updated.txt
          git diff --cached --quiet || git commit -m "chore: update last run time"
          git pull --rebase || true
          git push
```

- [ ] **Step 3: Create `README.md`** with: a one-paragraph intro; the prominent caveats block (monthly only, two metrics, distinct IPs non-additive, the download score definition, not comparable to cran-downloads/r2u, version-agnostic, history reconstructed from the Internet Archive during the 2026 outage); a Data Access section with `gh release download` plus R and Python snippets against `bioconductor-recent.db`; example queries (per-package monthly series, top packages by `download_score`, CRAN-vs-Bioc note); the schema tables for `bioc_downloads_monthly`, `bioc_downloads_yearly`, `bioc_downloads_summary`; an Attribution section crediting Bioconductor's `download_stats`; and an MIT License note. Mirror the structure and tone of `r2u-downloads/README.md`. No em dashes, no hard-wrapped prose.

- [ ] **Step 4: Create `last-updated.txt`** with a single line `Last updated: (pending first run)`.

- [ ] **Step 5: Commit**

```bash
git add .github README.md last-updated.txt
git commit -m "Add CI workflows and README"
```

- [ ] **Step 6: Local end-to-end smoke (manual, before enabling the schedule)**

Run the bootstrap against the live Wayback source into a scratch dir and inspect:

```bash
Rscript scripts/bootstrap-from-wayback.R /tmp/bioc-out
ls /tmp/bioc-out
Rscript -e "library(DBI); con <- dbConnect(RSQLite::SQLite(), '/tmp/bioc-out/bioconductor-summary.db'); print(head(dbGetQuery(con, 'SELECT package, category, download_score, rank_score FROM bioc_downloads_summary ORDER BY rank_score LIMIT 10')))"
cat /tmp/bioc-out/manifest.json
```

Expected: per-year shards from 2009 to the snapshot year, a `bioconductor-recent.db`, a `bioconductor-summary.db` whose top packages by `download_score` look plausible (for example `limma`, `DESeq2`), and a `manifest.json` with `source_kind: "wayback"` and `data_through.monthly` near `2026-01`. Do not enable the daily schedule until this looks right. This step validates cold-start runtime against the 60-minute CI budget.

---

## Self-Review

**1. Spec coverage:**
- Four categories with filename quirk: Task 1 (`category_tuples`, `category_file`).
- TSV parse by header: Task 2.
- Monthly/yearly split, `all` rows, non-additive yearly distinct IPs: Task 3.
- Future-placeholder drop, keep past zeros, anchor: Task 4.
- Year shards (monthly + yearly), PRAGMA/VACUUM: Task 5.
- Recent 36-month window: Task 6.
- Summary with official `download_score`, totals, ranks, trend, anchored to latest complete month: Task 7.
- Summary-only shard, `package_lower`: Task 8.
- HTTP-level change detection, manifest, coverage carry-forward: Task 9.
- Dual-source URL builders, release notes: Task 10.
- Availability gate (live/wayback/frozen/none), full rebuild, heartbeat, manifest provenance (`source_kind`, `granularities`, `data_through`): Task 11.
- Production IO with candidate-base probe and Wayback fallback, bootstrap entry: Task 12.
- Workflows, README caveats, first run: Task 13.
- Daily door: reserved via table names and `granularities`; no daily code (constraint honored, nothing to build).

**2. Placeholder scan:** Task 13 Step 3 (README) describes required sections rather than full file content; this is acceptable for a prose document whose exact wording follows the sibling README and the spec caveats verbatim, but the implementer should copy the caveat bullets from the design's "Semantic caveats" section. No code step uses a placeholder.

**3. Type consistency:** `SUMMARY_COLS` (Task 11) matches the `export_summary_shard` schema (Task 8) and the `summary_sql` output columns (Task 7). `source_files` entries carry `$hash` in both `resolve_source` (Tasks 11/12) and `diff_source_state` (Task 9). `export_shard(path, monthly, yearly = NULL)` is called with yearly in Task 11 year loop and without yearly for recent. `category_file(ct)` is the single key used by `resolve_source`, `fetch_sources`, and the parse loop, so map keys always align.
