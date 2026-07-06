test_that("parse_views_packages extracts Package names from DCF text", {
  text <- paste(
    "Package: limma",
    "Version: 3.60.0",
    "Depends: R (>= 4.4)",
    "",
    "Package: DESeq2",
    "Version: 1.44.0",
    sep = "\n")
  expect_equal(parse_views_packages(text), c("DESeq2", "limma"))  # sorted unique
})

test_that("parse_removed_packages reads both anchor hrefs and bare list items", {
  html <- paste0(
    "<a href=\"/packages/3.18/bioc/html/BioNetStat.html\">BioNetStat</a>",
    "<a href=\"/packages/3.20/data/annotation/html/foo.db.html\">foo.db</a>",
    "<li>ideogram</li><li>msbase</li>")
  expect_setequal(parse_removed_packages(html),
                  c("BioNetStat", "foo.db", "ideogram", "msbase"))
})
