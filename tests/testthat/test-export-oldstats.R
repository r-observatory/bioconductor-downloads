test_that("export_oldstats_shard writes the three archive tables with origin", {
  d <- withr::local_tempdir(); path <- file.path(d, "bioconductor-oldstats.db")
  monthly <- data.frame(package = "reticulate", category = "software",
    date = c("2019-01-01", "2019-02-01"), origin = "cran",
    n_distinct_ips = c(100L, 110L), n_downloads = c(400L, 440L),
    stringsAsFactors = FALSE)
  yearly <- data.frame(package = "reticulate", category = "software", year = 2019L,
    origin = "cran", n_distinct_ips_year = 900L, n_downloads_year = 5000L,
    stringsAsFactors = FALSE)
  summary <- data.frame(package = "reticulate", category = "software", origin = "cran",
    total_downloads = 840L, months_active = 2L,
    first_month = "2019-01-01", last_month = "2019-02-01", stringsAsFactors = FALSE)

  export_oldstats_shard(path, monthly, yearly, summary)

  con <- DBI::dbConnect(RSQLite::SQLite(), path); on.exit(DBI::dbDisconnect(con))
  expect_setequal(DBI::dbListTables(con),
    c("bioc_oldstats_monthly", "bioc_oldstats_yearly", "bioc_oldstats_summary"))
  m <- DBI::dbGetQuery(con, "SELECT * FROM bioc_oldstats_monthly ORDER BY date")
  expect_equal(m$origin, c("cran", "cran"))
  expect_equal(m$n_downloads, c(400L, 440L))
  s <- DBI::dbGetQuery(con, "SELECT * FROM bioc_oldstats_summary")
  expect_equal(s$total_downloads, 840L)
})
