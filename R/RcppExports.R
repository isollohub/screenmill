# This file was generated by Rcpp::compileAttributes
# Generator token: 10BE3573-1514-4C36-9D1C-5A225CD40393

measureColonies <- function(img, l, r, t, b, background, thresh) {
    .Call('screenmill_measureColonies', PACKAGE = 'screenmill', img, l, r, t, b, background, thresh)
}

nearestNeighbor <- function(x, y) {
    .Call('screenmill_nearestNeighbor', PACKAGE = 'screenmill', x, y)
}

