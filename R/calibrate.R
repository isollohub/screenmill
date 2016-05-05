# ---- Calibrate Cropping ----
#' Calibrate cropping and rotation parameters
#'
#' This function calibrates plate cropping and rotation parameters for an image
#' with an arbritrarily sized grid of plates.
#'
#' @param dir Directory of images to process.
#' @param rotate A rough angle in degrees clockwise to rotate each plate. The
#' rotation angle will be further calibrated after applying this rotation.
#' Defaults to \code{90}.
#' @param range Range to explore (in degrees) when calibrating rotation angle.
#' Defaults to \code{6}.
#' @param step Increment (in degrees) to step when calibrating rotation angle.
#' Defaults to \code{0.2}.
#' @param thresh Fraction of foreground pixels needed to identify plate
#' boundaries when rough cropping. Defaults to \code{0.03}.
#' @param invert Should the image be inverted? Defaults to \code{TRUE}.
#' Recommended \code{TRUE} if colonies are darker than the plate.
#' @param display Should cropped images be displayed for review?
#' Defaults to \code{TRUE}.
#' @param overwrite Should existing crop calibration be overwritten?
#' Defaults to \code{FALSE}.
#'
#' @details
#' Crop calibration procedes through the following 3 steps:
#'
#' \enumerate{
#'   \item Rough crop
#'   \item Rotate
#'   \item Fine crop
#' }
#'
#' Rough cropping relies on high contrast between plates. If
#' \code{invert = TRUE} plates should be light and the region between plates
#' should be dark, and vice versa if \code{invert = FALSE}.
#'
#' Rotation first applies the \code{rotate} argument, then iterates through
#' a range of degrees specified by the \code{range} argument with a step
#' specified by the \code{step} argument. The image is first thresholded to identify
#' objects (i.e. colonies) and the objects are expanded to get a rough shape of
#' their location on the plate. The final rotation angle is chosen
#' by minimizing the variance of rowwise sums for the range of rotation angles
#' explored, which effectively aligns a rectangular shape with the axes.
#'
#' Fine cropping finds the nearest object edge (problematic for plates without
#' any growth on the intended grid edges).
#'
#' @export

calibrate <- function(dir = '.', rotate = 90, range = 6, step = 0.2,
                      thresh = 0.03, invert = TRUE, rough_pad = c(0, 0, 0, 0),
                      fine_pad = c(5, 5, 5, 5), display = TRUE,
                      overwrite = FALSE) {

  # Save plot parameter defaults. Only necessary for bug in EBImage < 4.13.7
  if (display) { old <- par(no.readonly = TRUE); on.exit(par(old)) }

  # Validate input
  stopifnot(
    is.string(dir), is.dir(dir), is.number(rotate), is.number(range),
    is.number(step), is.number(thresh), is.flag(invert), is.flag(display),
    is.flag(overwrite), is.numeric(rough_pad), length(rough_pad) == 4,
    is.numeric(fine_pad), length(fine_pad) == 4
  )

  # Clean trailing slash from directory input
  dir <- gsub('/$', '', dir)
  plt_path <- file.path(dir, 'screenmill-annotations.csv', fsep = '/')
  crp_path <- file.path(dir, 'screenmill-calibration-crop.csv', fsep = '/')
  grd_path <- file.path(dir, 'screenmill-calibration-grid.csv', fsep = '/')
  key_path <- file.path(dir, 'screenmill-collection-keys.csv', fsep = '/')

  # Stop if plates have not yet been annotated
  if (!file.exists(plt_path)) stop('Could not find ', plt_path, '. Please annotate plates before cropping. See ?annotate for more details.')

  if (!overwrite && (file.exists(crp_path) || file.exists(grd_path))) {
    # Exit if already calibratd and no overwrite
    message('This batch has already been calibrated. Set "overwrite = TRUE" to re-calibrate.')
    return(invisible(dir))
  } else {
    # Remove pre-existing files
    if (file.exists(crp_path)) file.remove(crp_path)
    if (file.exists(grd_path)) file.remove(grd_path)
  }

  # Get paths to templates relative to dir, and corresponding plate positions
  annotation <-
    read_csv(plt_path) %>%
    select(template, position, strain_collection_id, plate) %>%
    mutate(template = paste(dir, template, sep = '/')) %>%
    distinct

  key <- read_csv(key_path)

  templates <- unique(annotation$template)

  # Record start time
  time <- Sys.time()

  # Calibrate each template by iterating through templates and positions
  lapply(
    templates, calibrate_template,
    # Arguments
    annotation, key, thresh, invert, rough_pad, fine_pad, rotate, range, step,
    display, crp_path, grd_path
  )

  message('Finished calibration in ', format(round(Sys.time() - time, 2)))
  return(invisible(dir))
}



# ---- Utilities: calibrate ---------------------------------------------------
# Calibrate a single template image
#
# @param template path to template image
# @param annotation table of plate annotations
# @param thresh ? TODO currently used to detect rough crop locations
# @param invert Should the image be inverted
# @param rough_pad Padding around rough crop
# @param fine_pad Padding to add around fine crop
# @param rotate Rough rotation angle in degrees
# @param range Range of angles to explore in degrees
# @param step Step interval to explore when optimizing rotation angle
# @param display Should calibration be displayed
# @param crp path to crop calibration output
# @param grd path to grid calibration output
#
#' @importFrom readr write_csv

calibrate_template <- function(template, annotation, key, thresh, invert, rough_pad,
                               fine_pad, rotate, range, step, display, crp, grd) {

  # Read image in greyscale format
  message(basename(template), ': reading image and cropping plates')
  img <- screenmill:::read_greyscale(template)

  # Filter annotation data for this template
  anno <- annotation[which(annotation$template == template), ]

  # Determine rough crop coordinates and apply to this image
  rough <- screenmill:::rough_crop(img, thresh, invert, rough_pad) %>% mutate_(template = ~basename(template))
  if (nrow(rough) > length(anno$position)) warning('For ', basename(template), ', keeping positions (', paste(anno$position, collapse = ', '), ') of ', nrow(rough), ' available.')
  if (display) screenmill:::display_rough_crop(img, rough, 'red')
  plates <- lapply(anno$position, function(p) with(rough, img[ rough_l[p]:rough_r[p], rough_t[p]:rough_b[p] ]))

  # Determine fine crop coordinates
  progress <- progress_estimated(length(anno$position))
  fine <-
    lapply(anno$position, function(p) {
      progress$tick()$print()
      screenmill:::fine_crop(plates[[p]], rotate, range, step, fine_pad, invert) %>%
        mutate(template = basename(template), position = p)
    }) %>%
    bind_rows

  # Determine grid coordinates
  message(basename(template), ': locating colony grid')
  progress <- progress_estimated(length(anno$position))
  grid <-
    lapply(1:length(anno$position), function(i) {
      progress$tick()$print()
      p <- anno$position[i]
      finei <- fine[which(fine$position == p), ]
      collection_id <- anno$strain_collection_id[p]
      collection_plate <- anno$plate[p]
      keyi <- with(key, key[which(strain_collection_id == collection_id & plate == collection_plate), ])
      plate <- plates[[p]]

      if (invert) plate <- 1 - plate
      rotated <- EBImage::rotate(plate, finei$rotate)
      cropped <- with(finei, rotated[fine_l:fine_r, fine_t:fine_b])

      result <- screenmill:::locate_grid(cropped, radius = 0.9)

      if (is.null(result)) {
        warning(
          'Failed to locate colony grid for ', basename(template),
          ' at position ', p, '. This plate position has been skipped.')
      } else {
        # Annotate result with template, position, strain collection and plate
        result <-
          mutate_(result, template = ~basename(template), position = ~p) %>%
          left_join(mutate_(anno, template = ~basename(template)), by = c('template', 'position'))

        # Check the grid size and compare to expected plate size
        replicates <- nrow(result) / nrow(keyi)

        if (sqrt(replicates) %% 1 != 0) {
          warning(
            'Size of detected colony grid (', nrow(result), ') for ',
            basename(template), ' at position ', p,
            ' is not a square multiple of the number of annotated positions (',
            nrow(keyi), ') present in the key for ', collection_id,
            ' plate #', collection_plate, '.'
          )
        } else {
          # Annotate with key row/column/replicate values
          key_rows <- sort(unique(keyi$row))
          key_cols <- sort(unique(keyi$column))
          n_rows   <- length(key_rows)
          n_cols   <- length(key_cols)
          sqrt_rep <- sqrt(replicates)
          one_mat  <- matrix(rep(1, times = nrow(keyi)), nrow = n_rows, ncol = n_cols)

          rep_df <-
            (one_mat %x% matrix(1:replicates, byrow = T, ncol = sqrt_rep)) %>%
            as.data.frame %>%
            add_rownames('colony_row') %>%
            gather('colony_col', 'replicate', starts_with('V')) %>%
            mutate(
              colony_row = as.integer(colony_row),
              colony_col = as.integer(gsub('V', '', colony_col))
            )

          col_df <-
            matrix(rep(key_cols, each = n_rows * replicates), ncol = n_cols * sqrt_rep) %>%
            as.data.frame %>%
            add_rownames('colony_row') %>%
            gather('colony_col', 'column', starts_with('V')) %>%
            mutate(
              colony_row = as.integer(colony_row),
              colony_col = as.integer(gsub('V', '', colony_col))
            )

          row_df <-
            matrix(rep(key_rows, each = n_cols * replicates), nrow = n_rows * sqrt_rep, byrow = T) %>%
            as.data.frame %>%
            add_rownames('colony_row') %>%
            gather('colony_col', 'row', starts_with('V')) %>%
            mutate(
              colony_row = as.integer(colony_row),
              colony_col = as.integer(gsub('V', '', colony_col))
            )

          result <-
            result %>%
            left_join(row_df, by = c('colony_row', 'colony_col')) %>%
            left_join(col_df, by = c('colony_row', 'colony_col')) %>%
            left_join(rep_df, by = c('colony_row', 'colony_col')) %>%
            select(template:replicate, colony_row:background, everything())
        }
      }

      if (display) display_plate(cropped, result, template, p, text.color = 'red', grid.color = 'blue')

      return(result)
    }) %>%
    bind_rows

  # Combine rough and fine crop coordinates
  crop <-
    left_join(rough, fine, by = c('template', 'position')) %>%
    mutate_(invert = ~invert) %>%
    select_(~template, ~position, ~everything())

  # Write results to file
  write_csv(crop, crp, append = file.exists(crp))
  write_csv(grid, grd, append = file.exists(grd))
}


# ---- Display functions ------------------------------------------------------
display_rough_crop <- function(img, rough, color) {
  EBImage::display(img, method = 'raster')
  with(rough, segments(rough_l, rough_t, rough_r, rough_t, col = color))
  with(rough, segments(rough_l, rough_b, rough_r, rough_b, col = color))
  with(rough, segments(rough_l, rough_t, rough_l, rough_b, col = color))
  with(rough, segments(rough_r, rough_t, rough_r, rough_b, col = color))
  with(rough, text(plate_x, plate_y, position, col = color))
}

display_plate <- function(img, grid, template, position, text.color, grid.color) {
  EBImage::display(img, method = 'raster')

  if (!is.null(grid)) {
    with(grid, segments(l, t, r, t, col = grid.color))
    with(grid, segments(l, b, r, b, col = grid.color))
    with(grid, segments(l, t, l, b, col = grid.color))
    with(grid, segments(r, t, r, b, col = grid.color))
  }

  x <- nrow(img) / 2
  y <- ncol(img) / 2
  text(x, y, labels = paste(basename(template), position, sep = '\n'), col = text.color, cex = 1.5)
}

# ---- Locate Colony Grid -----------------------------------------------------
# Locate grid and determine background pixel intensity for a single image
#
# @param img An Image object or matrix. See \link[EBImage]{Image}.
# @param radius Fraction of the average distance between row/column centers and
# edges. Affects the size of the selection box for each colony. Defaults to
# 0.9 (i.e. 90%).
#
#' @importFrom tidyr complete

locate_grid <- function(img, radius = 0.9) {

  # Scale image for rough object detection
  rescaled <- EBImage::normalize(img, inputRange = c(0.1, 0.8))

  # Blur image to combine spotted colonies into single objects for threshold
  blr <- EBImage::gblur(rescaled, sigma = 6)
  thr <- EBImage::thresh(blr, w = 15, h = 15, offset = 0.05)

  # label objects using watershed algorithm to be robust to connected objects
  wat <- EBImage::watershed(EBImage::distmap(thr))

  # Detect rough location of rows and columns
  cols <- grid_breaks(thr, 'col', thresh = 0.07, edges = 'mid')
  rows <- grid_breaks(thr, 'row', thresh = 0.07, edges = 'mid')
  col_centers <- ((cols + lag(cols)) / 2)[-1]
  row_centers <- ((rows + lag(rows)) / 2)[-1]

  if (length(col_centers) < 1 || length(row_centers) < 1) return(NULL)

  # Characterize objects and bin them into rows/columns
  objs <-
    object_features(wat) %>%
    filter(eccen < 0.8) %>%   # remove weird objects
    mutate(
      colony_row = cut(y, rows, labels = FALSE),
      colony_col = cut(x, cols, labels = FALSE)
    )

  # If multiple objects are found in a grid location, choose largest object
  rough_grid <-
    objs %>%
    group_by(colony_row, colony_col) %>%
    summarise(x = x[which.max(area)], y = y[which.max(area)]) %>%
    ungroup

  # Determine x/y coordinates of each grid location
  fine_grid <-
    rough_grid %>%
    # Fill missing row/column combinations with NA
    complete(colony_row, colony_col) %>%
    # Determine row locations
    group_by(colony_row) %>%
    arrange(colony_col) %>%
    mutate(
      # If missing, use estimated center
      y = ifelse(is.na(y), row_centers[colony_row], y),
      y = round(predict(smooth.spline(colony_col, y), colony_col)[[2]])
    ) %>%
    # Determine column locations
    group_by(colony_col) %>%
    arrange(colony_row) %>%
    mutate(
      # If missing, use estimated center
      x = ifelse(is.na(x), col_centers[colony_col], x),
      x = round(predict(smooth.spline(colony_row, x), colony_row)[[2]])
    ) %>%
    ungroup

  # Add a selection box
  selection <-
    fine_grid %>%
    mutate(
      radius = round(((mean(diff(rows)) + mean(diff(cols))) / 4) * radius),
      l = x - radius,
      r = x + radius,
      t = y - radius,
      b = y + radius,
      # Fix edges if radius is out of bounds of image
      l = as.integer(round(ifelse(l < 1, 1, l))),
      r = as.integer(round(ifelse(r > nrow(img), nrow(img), r))),
      t = as.integer(round(ifelse(t < 1, 1, t))),
      b = as.integer(round(ifelse(b > ncol(img), ncol(img), b))),
      # Identify corner intensities,
      tl = img[as.matrix(cbind(l, t))],
      tr = img[as.matrix(cbind(r, t))],
      bl = img[as.matrix(cbind(l, b))],
      br = img[as.matrix(cbind(r, b))],
      bg = apply(cbind(tl, tr, bl, br), 1, mean, trim = 0.5)
    )

  # Predict background intensity via loess smoothing
  selection$background <-
    loess(bg ~ colony_row + colony_col, data = selection, span = 0.3, normalize = F, degree = 2) %>%
    predict

  return(selection %>% select(colony_row, colony_col, x, y, l, r, t, b, background))
}

# ---- Display Calibration: TODO ----------------------------------------------
# Display crop calibration
#
# Convenience function for displaying crop calibrations. Usefull for viewing
# the result of manually edited
#
# @param dir Directory of images
# @param groups Cropping groups to display. Defaults to \code{NULL} which will
# display all groups.
# @param positions Positions to display. Defaults to \code{NULL} which will
# display all positions.
#
# @export

display_calibration <- function(dir = '.', groups = NULL, positions = NULL) {
  # only necessary for bug in EBImage < 4.13.7
  old <- par(no.readonly = TRUE)
  on.exit(par(old))

  # Find screenmill-annotations
  dir <- gsub('/$', '', dir)
  if (is.dir(dir)) {
    path <- paste(dir, 'screenmill-annotations.csv', sep = '/')
  } else {
    path <- dir
  }
  if (!file.exists(path)) {
    stop('Could not find ', path, '. Please annotate plates before cropping.
         See ?annotate for more details.')
  }

  calibration <- screenmill_annotations(path)
  if (!is.null(groups)) {
    calibration <- filter(calibration, group %in% c(0, groups))
  }
  if (!is.null(positions)) {
    calibration <- filter(calibration, position %in% c(0, positions))
  }

  files <- paste0(dir, '/', unique(calibration$template))
  for (file in files) {

    # Get data for file
    coords <- calibration[which(calibration$file == basename(file)), ]

    # Read as greyscale image
    img <- EBImage::readImage(file)
    if (EBImage::colorMode(img)) {
      img <- EBImage::channel(img, 'luminance')
    }

    # Apply Crop calibration
    lapply(1:nrow(coords), function(p) {
      rough   <- with(coords, img[ left[p]:right[p], top[p]:bot[p] ])
      rotated <- rotate(rough, coords$rotate[p])
      fine    <- with(coords, rotated[ fine_left[p]:fine_right[p], fine_top[p]:fine_bot[p] ])
      EBImage::display(fine, method = 'raster')
      x <- nrow(fine) / 2
      y <- ncol(fine) / 2
      text(x, y, labels = paste0('Group: ', coords$group[p], '\nPosition: ', coords$position[p]), col = 'red', cex = 1.5)
    })
  }
  return(invisible(dir))
}