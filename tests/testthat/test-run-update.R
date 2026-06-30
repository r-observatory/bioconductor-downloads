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
