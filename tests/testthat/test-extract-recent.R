test_that("extract_recent_monthly returns only the trailing window ending at the anchor", {
  rows <- data.frame(
    package = "p", category = "software",
    date = c("2023-01-01", "2024-01-01", "2025-12-01", "2026-01-01"),
    n_distinct_ips = 1L, n_downloads = 1L, stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))
  rec <- extract_recent_monthly(con, "2026-01-01", months = 36L)  # cutoff 2023-02-01
  expect_setequal(rec$date, c("2024-01-01", "2025-12-01", "2026-01-01"))
})
