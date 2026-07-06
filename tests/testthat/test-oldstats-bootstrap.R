fake_oldstats_io <- function(tmp, now = as.POSIXct("2026-07-06 12:00:00", tz = "UTC")) {
  cts <- category_tuples()
  src <- file.path(tmp, "src"); dir.create(src, recursive = TRUE, showWarnings = FALSE)
  files <- list()
  for (ct in cts) {
    body <- paste(
      "Package\tYear\tMonth\tNb_of_distinct_IPs\tNb_of_downloads",
      "limma\t2015\tJan\t50\t120",          # a real Bioc package (in roster)
      "limma\t2015\tall\t50\t120",
      "reticulate\t2015\tJan\t900\t4000",   # a CRAN package via the mirror (not in roster)
      "reticulate\t2015\tall\t900\t4000",
      "reticulate\t2025\tMay\t0\t0",        # post-freeze zero placeholder, dropped
      sep = "\n")
    f <- file.path(src, paste0(ct$dir, "_", ct$prefix, "pkg_stats.tab"))
    writeLines(body, f); files[[paste0(ct$dir, "|", ct$prefix)]] <- f
  }
  list(
    bioc_roster    = function() c("limma", "DESeq2", "org.Hs.eg.db"),
    fetch_oldstats = function(dir, file) {
      key <- paste0(dir, "|", sub("pkg_stats.tab$", "", file)); files[[key]]
    },
    now = function() now)
}

test_that("run_oldstats_bootstrap builds the archive DB and tags origin", {
  tmp <- withr::local_tempdir(); out <- file.path(tmp, "out")
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  block <- run_oldstats_bootstrap(fake_oldstats_io(tmp), out)

  path <- file.path(out, "bioconductor-oldstats.db")
  expect_true(file.exists(path))
  con <- DBI::dbConnect(RSQLite::SQLite(), path); on.exit(DBI::dbDisconnect(con))
  m <- DBI::dbGetQuery(con, "SELECT DISTINCT package, origin FROM bioc_oldstats_monthly ORDER BY package")
  expect_equal(m$origin[m$package == "limma"][1], "bioc")
  expect_equal(m$origin[m$package == "reticulate"][1], "cran")
  # The 2025-05 zero placeholder was dropped; only 2015-01 remains per package.
  dates <- DBI::dbGetQuery(con, "SELECT DISTINCT date FROM bioc_oldstats_monthly")$date
  expect_equal(dates, "2015-01-01")

  expect_equal(block$frozen_through, "2015-01-01")
  expect_true(block$origin_counts$bioc >= 1)
  expect_true(block$origin_counts$cran >= 1)
})
