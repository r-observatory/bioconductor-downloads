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
