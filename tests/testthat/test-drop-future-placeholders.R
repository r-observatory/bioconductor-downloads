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
