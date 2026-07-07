# sf-30x30-canopy-restoration

LiDAR processing pipeline using lidR to drive biodiversity restoration across
San Francisco's central open spaces. Combines 3D metric extraction and ML to
map invasive ivy, blackberry thickets, and senescent eucalyptus—optimizing
field interventions for California's 30×30 grant goals.

---

## Pipeline overview

The analysis is split into three numbered scripts plus a shared config file.
Run them in order, or use `run_pipeline.R` to execute all steps at once.

| Script | Purpose |
|---|---|
| `config.R` | Shared settings (CRS, paths, algorithm parameters). Edit this first. |
| `01_load_data.R` | Load the LiDAR catalog (`tilecls/`) and clip to the analysis area. |
| `02_segment.R` | Normalize heights, detect tree tops, segment trees, classify snags, and **save** the result to `LHH_aa_z3segssnags.las`. |
| `03_visualize.R` | Load the saved LAS, compute crown metrics, and display an interactive map on the SF Pictometry 2024 aerial. |
| `run_pipeline.R` | Master runner – sources each step in order with configurable flags. |
| `LHHtrees2023/app.R` | Shiny app for interactive exploration; can be deployed to shinyapps.io. |

### Running the full pipeline

```r
source("run_pipeline.R")
```

### Skipping segmentation (already done)

Segmentation (`02_segment.R`) is the slowest step. Once
`LHH_aa_z3segssnags.las` exists, `run_pipeline.R` skips it automatically.
To force a re-run, set `FORCE_SEGMENT <- TRUE` at the top of `run_pipeline.R`.

You can also run individual steps directly:

```r
source("01_load_data.R")   # populates `las` in memory
source("02_segment.R")     # uses `las`; saves result to disk
source("03_visualize.R")   # reads from disk; opens interactive map
```

### Test area vs. full area

Edit `USE_CUSTOM_CIRCLE` in `config.R`:

- `FALSE` (default) – full LHH analysis area from `updatedAA.kml` (~134,000 m²)
- `TRUE` – small DLT_040 test circle (r = 40 m, ~5,000 m²); faster for testing

---

## Data sources

- **LiDAR tiles** (not in repo): USGS 2023 San Francisco 3D point cloud  
  <https://apps.nationalmap.gov/downloader/>  
  Local tiles expected at `tilecls/`
- **Analysis area**: `updatedAA.kml`
- **Aerial imagery**: SF DPW Pictometry 2024 (tile service, loaded at runtime)
