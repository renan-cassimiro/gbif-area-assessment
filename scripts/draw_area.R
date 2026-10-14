# Draw ONE study-area polygon and save it as a GPKG (to be used with input.area.mode: "gpkg").
# Run from an interactive R console (works in RStudio Desktop and RStudio Server):
#   source("scripts/draw_area.R")

out <- "data/input/areas.gpkg"
app <- new.env(parent = globalenv())
for (f in sort(list.files("R", pattern = "\\.R$", full.names = TRUE))) sys.source(f, envir = app)
app$setup_logging("INFO")
if (file.exists(out)) stop("Refusing to overwrite ", out, "; move it or change `out`.")
area <- app$draw_area()
sf::st_write(area, out, quiet = TRUE)
message("Saved: ", out, "  (set input.area.mode: \"gpkg\" and input.area.path in config.yaml)")
