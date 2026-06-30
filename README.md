# Bioconductor Downloads

Monthly download statistics for [Bioconductor](https://bioconductor.org/) packages, covering all four package categories (software, data-annotation, data-experiment, and workflows). Counts are sourced from the per-category aggregate `.tab` files that Bioconductor regenerates twice weekly under `/packages/stats/`. Data is published as a set of SQLite shard files attached to a single rolling GitHub release tag (`current`). Because the canonical stats endpoint has been in outage since approximately June 2026, the initial archive is bootstrapped from Internet Archive snapshots through about January 2026; the pipeline auto-switches to the live source the next time the endpoint returns.

> [!IMPORTANT]
> **What these numbers mean, and what they do not.**
>
> - **Monthly only.** Bioconductor publishes no daily per-package counts. This is a source constraint, not a pipeline choice. Every row in `bioc_downloads_monthly` represents one calendar month.
> - **Two metrics, one non-additive.** Each month carries `n_downloads` (raw hit count, additive across months) and `n_distinct_ips` (unique source IPs, a bot dampener). Distinct IPs are **not additive across time**: the yearly `all` row is de-duplicated across the whole year and is strictly smaller than the sum of the monthly figures. Never sum `n_distinct_ips` across periods; use the yearly row or the `download_score`.
> - **Download score definition.** Bioconductor's headline metric, `download_score`, is the average number of distinct IPs per month over the trailing 12 complete months, excluding the current (partial) month. Ranks in `bioc_downloads_summary` are computed **within each category** (software, data-annotation, data-experiment, workflows), not across all packages.
> - **Not comparable to `cran-downloads` or `r2u-downloads`.** CRAN download logs are daily, single-mirror, and split by version and OS. r2u counts are raw apt fetches of `.deb` binaries. Bioconductor stats are monthly, version-agnostic, and cover all package file types combined with no OS, architecture, or country breakdown. Different populations, different methods: do not compare magnitudes.
> - **History reconstructed from the Internet Archive.** During the 2026 Bioconductor stats outage, the pipeline bootstrapped historical data from Internet Archive snapshots. Coverage is complete through approximately January 2026, with a gap from that point until the canonical endpoint is restored. The `source_kind` and `data_through` fields in `manifest.json` expose exactly which months are present and where they came from.
> - **Canonical package names.** Package names use the canonical Bioconductor case (`DESeq2`, `limma`, `a4Base`). The helper column `package_lower` in the summary table facilitates case-insensitive joins.

## Data Access

All shards live as assets on the [`current` release](https://github.com/r-observatory/bioconductor-downloads/releases/tag/current). Each run uploads only the shards that changed; the rest remain unchanged.

### Recent data (last 36 months)

For most use cases this is the only file you need. It contains the rolling 36-month window of `bioc_downloads_monthly` plus the full `bioc_downloads_summary` table.

```bash
gh release download current \
  --repo r-observatory/bioconductor-downloads \
  --pattern "bioconductor-recent.db"
```

```r
url <- "https://github.com/r-observatory/bioconductor-downloads/releases/download/current/bioconductor-recent.db"
download.file(url, "bioconductor-recent.db", mode = "wb")

library(RSQLite)
con <- dbConnect(SQLite(), "bioconductor-recent.db")

# Monthly download series for DESeq2 over the last 12 months
dbGetQuery(con, "
  SELECT date, n_distinct_ips, n_downloads
  FROM bioc_downloads_monthly
  WHERE package = 'DESeq2'
    AND category = 'software'
  ORDER BY date DESC LIMIT 12
")

# Top 20 software packages by download score
dbGetQuery(con, "
  SELECT package, download_score, total_12mo, rank_score
  FROM bioc_downloads_summary
  WHERE category = 'software'
  ORDER BY rank_score LIMIT 20
")

dbDisconnect(con)
```

```python
import urllib.request, sqlite3
url = "https://github.com/r-observatory/bioconductor-downloads/releases/download/current/bioconductor-recent.db"
urllib.request.urlretrieve(url, "bioconductor-recent.db")

con = sqlite3.connect("bioconductor-recent.db")
for row in con.execute("""
    SELECT package, download_score, total_12mo, rank_score
    FROM bioc_downloads_summary
    WHERE category = 'software'
    ORDER BY rank_score LIMIT 10"""):
    print(row)
con.close()
```

### Per-year archives

Each calendar year has its own shard (software history begins in 2009; other categories start somewhat later):

```bash
gh release download current \
  --repo r-observatory/bioconductor-downloads \
  --pattern "bioconductor-2024.db"
```

### Full history (all years)

```bash
gh release download current \
  --repo r-observatory/bioconductor-downloads \
  --pattern "bioconductor-*.db"
```

To query across years, ATTACH the shards or UNION them (the `package` and `category` keys are consistent across shards, so unions are safe):

```r
library(RSQLite)
con <- dbConnect(SQLite(), ":memory:")
for (yr in 2009:2026) {
  shard <- sprintf("bioconductor-%04d.db", yr)
  if (file.exists(shard)) dbExecute(con, sprintf("ATTACH '%s' AS y%d", shard, yr))
}
```

### Summary only

For top-package lists, ranks, and trends with the smallest download:

```bash
gh release download current \
  --repo r-observatory/bioconductor-downloads \
  --pattern "bioconductor-summary.db"
```

### Manifest

`manifest.json` lists which shards changed in the most recent run, the source kind (`live`, `wayback`, or `frozen`), granularities present, data coverage through date, and freshness timestamps (`last_checked`, `last_changed`). It is the authoritative record of what data is present and where it came from.

```bash
gh release download current \
  --pattern manifest.json \
  --repo r-observatory/bioconductor-downloads
cat manifest.json
```

## Example Queries

### Monthly download series for a package

```sql
SELECT date, n_distinct_ips, n_downloads
  FROM bioc_downloads_monthly
 WHERE package = 'limma'
   AND category = 'software'
 ORDER BY date DESC
 LIMIT 24;
```

### Top packages by download score, within a category

Note that `rank_score` is ranked within each category separately. To compare across categories, sort by `download_score` directly and filter as needed.

```sql
SELECT package, download_score, total_12mo, rank_score, trend
  FROM bioc_downloads_summary
 WHERE category = 'software'
 ORDER BY rank_score
 LIMIT 50;
```

### Trend comparison: faster-growing packages

```sql
SELECT package, download_score, trend
  FROM bioc_downloads_summary
 WHERE category = 'software'
   AND trend IS NOT NULL
 ORDER BY trend DESC
 LIMIT 20;
```

### A note on CRAN vs Bioconductor comparisons

The `n_downloads` figures in this dataset are **not comparable** to CRAN download counts from `r-observatory/cran-downloads`. CRAN's cranlogs are daily counts from a single mirror (the Posit mirror), split by version and OS. Bioconductor's counts are monthly, version-agnostic, and reflect all access methods combined. A package available on both CRAN and Bioconductor (such as `BiocGenerics`) will show separate figures in each dataset with no meaningful relationship in magnitude.

## Schema

### `bioc_downloads_monthly`

Monthly download counts per package and category. Present in `bioconductor-recent.db` (last 36 months) and in each `bioconductor-YYYY.db` archive. Dates use the first-of-month convention (`YYYY-MM-01`). Future-month zero placeholders are dropped; genuine past zeros are retained.

| Column | Type | Description |
|---|---|---|
| `package` | TEXT | Canonical Bioconductor package name (PK part 1) |
| `category` | TEXT | `software`, `data-annotation`, `data-experiment`, or `workflows` (PK part 2) |
| `date` | TEXT | `YYYY-MM-01`, first of month (PK part 3) |
| `n_distinct_ips` | INTEGER | Unique source IPs that month (non-additive across months) |
| `n_downloads` | INTEGER | Raw download count that month (additive across months) |

### `bioc_downloads_yearly`

Yearly aggregates taken verbatim from the source `all` rows, never recomputed from the monthly figures. Present in each `bioconductor-YYYY.db`. The `n_distinct_ips_year` column reflects year-level de-duplication by Bioconductor; it is smaller than the sum of the monthly `n_distinct_ips` values.

| Column | Type | Description |
|---|---|---|
| `package` | TEXT | Canonical Bioconductor package name (PK part 1) |
| `category` | TEXT | Package category (PK part 2) |
| `year` | INTEGER | Calendar year (PK part 3) |
| `n_distinct_ips_year` | INTEGER | Year-unique distinct IPs from the `all` row; do not sum monthly values |
| `n_downloads_year` | INTEGER | Total downloads for the year from the `all` row; equals the sum of the monthly values |

### `bioc_downloads_summary`

Aggregated statistics per package and category, rebuilt each run. Present in `bioconductor-recent.db` and `bioconductor-summary.db`. All windows are anchored to the latest complete month in the data (not the current calendar date), because the source lags and the current month is partial.

| Column | Type | Description |
|---|---|---|
| `package` | TEXT | Canonical Bioconductor package name (PK part 1) |
| `package_lower` | TEXT | Lowercased helper column for case-insensitive joins |
| `category` | TEXT | Package category (PK part 2) |
| `download_score` | REAL | Mean monthly `n_distinct_ips` over the trailing 12 complete months, excluding the current partial month; Bioconductor's headline metric |
| `total_last_month` | INTEGER | `n_downloads` in the latest complete month |
| `total_12mo` | INTEGER | `n_downloads` summed over the trailing 12 complete months (additive) |
| `rank_score` | INTEGER | Rank by `download_score` within `category` |
| `rank_downloads_12mo` | INTEGER | Rank by `total_12mo` within `category` |
| `trend` | REAL | Percent change: last-3-complete-months downloads vs prior 3 months; `NULL` when the prior window is empty |

## How it works

A daily GitHub Actions job (06:00 UTC) probes the canonical Bioconductor stats endpoint and compares per-file content identity (HTTP `ETag`, `Last-Modified`, and SHA-256 hash) against the last run recorded in `manifest.json`. When the source is unavailable and a release already exists, the run is a cheap heartbeat that refreshes `last_checked` only. When the source is unavailable and no release exists, the pipeline bootstraps history from pinned Internet Archive snapshots. When the source returns and any file changed, the pipeline runs a full rebuild: it fetches all four category files, parses them with base R, splits monthly rows from yearly `all` rows, drops future-month zero placeholders, maps month tokens to `YYYY-MM-01` dates, assembles per-year shards, assembles the rolling 36-month `bioconductor-recent.db`, computes the summary table in SQL, and uploads only the changed shards to the `current` release (with `manifest.json` uploaded last so a crash leaves the prior state intact).

## Attribution

Download statistics are sourced from Bioconductor's published per-category aggregate `.tab` files, produced by the [`Bioconductor/download_stats`](https://github.com/Bioconductor/download_stats) pipeline. This repository provides only the aggregation and packaging into SQLite; the underlying data originates from Bioconductor infrastructure. Please credit the Bioconductor project when using these numbers.

## License

The pipeline code in this repository is released under the [MIT License](LICENSE). The underlying download statistics originate from Bioconductor; please respect Bioconductor's terms when redistributing.
