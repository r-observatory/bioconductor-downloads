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
