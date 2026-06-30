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
