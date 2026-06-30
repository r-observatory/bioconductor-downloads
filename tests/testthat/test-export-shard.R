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
