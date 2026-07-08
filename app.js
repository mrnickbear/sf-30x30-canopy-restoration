/* ============================================================
   SF 30×30 Canopy Restoration – app.js
   Leaflet 2D map + Deck.gl 3D view + linked data table
   ============================================================ */

// ── Configuration (mirrors config.R) ──────────────────────────
const PICTOMETRY_URL =
  "https://maps.sfdpw.org/arcgis/rest/services/Pictometry/Pictometry2024/MapServer/tile/{z}/{y}/{x}";
const CROWNS_GEOJSON  = "data/vector/crowns.geojson";
// Default map center: Laguna Honda Hospital (LHH) area, SF
const DEFAULT_CENTER  = [37.75011333486208, -122.45934823666263];
const DEFAULT_ZOOM    = 18;

// 3D point cloud threshold (mirrors config.R WEB_POINT_CLOUD_MIN_HEIGHT_M)
const WEB_POINT_CLOUD_MIN_HEIGHT_M = 42.5;
const WEB_POINT_CLOUD_DIR          = "data/web_point_clouds";

// Affine transform: local LAS CRS → WGS84
// Fitted by least-squares from (XTOP, YTOP) → crown-polygon-centroid pairs in crowns.geojson.
// lon = LON_A*X + LON_B*Y + LON_C
// lat = LAT_A*X + LAT_B*Y + LAT_C
const LON_A =  1.56396015e-6;
const LON_B = -1.26950611e-6;
const LON_C = -122.50258576;
const LAT_A =  4.80157997e-7;
const LAT_B =  3.33684245e-6;
const LAT_C =  37.64670385;

// ── Viridis-like 5-stop colour scale ──────────────────────────
const VIRIDIS = [
  [68,   1, 84],
  [59,  82, 139],
  [33, 145, 140],
  [94, 201, 97],
  [253, 231, 37],
];

function viridisColor(t) {
  // t in [0,1] → interpolated RGB
  const n = VIRIDIS.length - 1;
  const i = Math.min(Math.floor(t * n), n - 1);
  const f = t * n - i;
  const a = VIRIDIS[i];
  const b = VIRIDIS[i + 1];
  return [
    Math.round(a[0] + (b[0] - a[0]) * f),
    Math.round(a[1] + (b[1] - a[1]) * f),
    Math.round(a[2] + (b[2] - a[2]) * f),
  ];
}

function rgbCss(rgb, alpha = 1) {
  return `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${alpha})`;
}

// ── 3D-viewable helpers ───────────────────────────────────────
function is3DViewable(ztop) {
  return typeof ztop === "number" && ztop >= WEB_POINT_CLOUD_MIN_HEIGHT_M;
}

// Convert local LAS CRS coordinates to [longitude, latitude]
function localToLngLat(x, y) {
  return [
    LON_A * x + LON_B * y + LON_C,
    LAT_A * x + LAT_B * y + LAT_C,
  ];
}

// Zero-pad width mirrors 04_pointcloud_web_prep.R (max digits of viewable treeIDs).
// Computed once after geojsonData is loaded; cached in _lasPad.
let _lasPad = 0;
function lasPadWidth() {
  if (_lasPad) return _lasPad;
  if (!geojsonData) return 2;
  for (const f of geojsonData.features) {
    if (is3DViewable(f.properties?.ZTOP)) {
      _lasPad = Math.max(_lasPad, String(f.properties.treeID ?? "").length);
    }
  }
  return _lasPad || 2;
}

function lasUrl(treeID) {
  return `${WEB_POINT_CLOUD_DIR}/tree_${String(treeID).padStart(lasPadWidth(), "0")}.las`;
}

// ── Shared state ──────────────────────────────────────────────
let geojsonData    = null;
let heightMin      = 0;
let heightMax      = 1;
let selectedId     = null;   // currently selected treeID
let leafletLayers  = {};     // treeID → Leaflet layer
let tableRows      = [];     // [{feature, tr}]
let sortCol        = "ZTOP";
let sortDir        = "desc";
let searchQuery    = "";
let deckGL         = null;
let showBasemap    = true;

// ── Utility: normalise height value ───────────────────────────
function heightNorm(z) {
  if (heightMax === heightMin) return 0.5;
  return Math.max(0, Math.min(1, (z - heightMin) / (heightMax - heightMin)));
}

function featureColor(feature) {
  const props = feature.properties || {};
  if (props.snagCls > 0) return [248, 81, 73];   // red for snags
  const z = props.ZTOP ?? 0;
  return viridisColor(heightNorm(z));
}

// ── Draw legend gradient on a canvas ──────────────────────────
function drawLegend(canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx    = canvas.getContext("2d");
  const grad   = ctx.createLinearGradient(0, 0, canvas.width, 0);
  for (let s = 0; s <= 1; s += 0.05) {
    const rgb = viridisColor(s);
    grad.addColorStop(s, `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`);
  }
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
}

function updateLegendLabels() {
  ["legend-min", "deck-legend-min"].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = heightMin.toFixed(1) + " m";
  });
  ["legend-max", "deck-legend-max"].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = heightMax.toFixed(1) + " m";
  });
}

// ── Status bar helper ──────────────────────────────────────────
function setStatus(msg) {
  const el = document.getElementById("status-msg");
  if (el) el.textContent = msg;
}

// ── Tab switching ──────────────────────────────────────────────
document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach(b => {
      b.classList.remove("active");
      b.setAttribute("aria-selected", "false");
    });
    document.querySelectorAll(".panel").forEach(p => p.classList.remove("active"));
    btn.classList.add("active");
    btn.setAttribute("aria-selected", "true");
    const panel = document.getElementById(btn.dataset.panel);
    if (panel) panel.classList.add("active");
  });
});

// ══════════════════════════════════════════════════════════════
// SECTION 1 – Fetch GeoJSON and boot everything
// ══════════════════════════════════════════════════════════════
async function init() {
  setStatus("Fetching crowns.geojson…");

  // Browsers block fetch() on file:// — must be served over HTTP.
  if (location.protocol === "file:") {
    const hint = document.createElement("span");
    hint.textContent = "⚠ Could not load crowns.geojson: open via a local server — e.g. ";
    const code = document.createElement("code");
    code.textContent = "servr::httd(port = 8080)";
    const link = document.createElement("a");
    link.href = "http://localhost:8080";
    link.target = "_blank";
    link.textContent = "http://localhost:8080";
    hint.appendChild(code);
    hint.appendChild(document.createTextNode(" then visit "));
    hint.appendChild(link);
    const statusEl = document.getElementById("status-msg");
    statusEl.textContent = "";
    statusEl.appendChild(hint);
    const cell = document.createElement("td");
    cell.colSpan = 5;
    cell.className = "loading-cell";
    cell.appendChild(hint.cloneNode(true));
    const tr = document.createElement("tr");
    tr.appendChild(cell);
    const tbody = document.getElementById("table-body");
    tbody.textContent = "";
    tbody.appendChild(tr);
    return;
  }

  try {
    const res = await fetch(CROWNS_GEOJSON);
    if (!res.ok) throw new Error(`HTTP ${res.status} – ${res.statusText}`);
    geojsonData = await res.json();
  } catch (err) {
    setStatus(`⚠ Could not load crowns.geojson: ${err.message}`);
    const cell = document.createElement("td");
    cell.colSpan = 5;
    cell.className = "loading-cell";
    cell.textContent = `⚠ ${err.message}`;
    const tr = document.createElement("tr");
    tr.appendChild(cell);
    const tbody = document.getElementById("table-body");
    tbody.textContent = "";
    tbody.appendChild(tr);
    return;
  }

  // Compute height extent from ZTOP
  const heights = geojsonData.features
    .map(f => f.properties?.ZTOP)
    .filter(z => z != null && isFinite(z));
  if (heights.length) {
    heightMin = Math.min(...heights);
    heightMax = Math.max(...heights);
  }

  const total = geojsonData.features.length;
  document.getElementById("crown-count").textContent =
    `${total.toLocaleString()} trees`;
  setStatus(`Loaded ${total.toLocaleString()} tree crowns.`);

  drawLegend("legend-canvas");
  drawLegend("deck-legend-canvas");
  updateLegendLabels();

  initLeaflet();
  initTable();
}

// ══════════════════════════════════════════════════════════════
// SECTION 2 – Leaflet 2D map
// ══════════════════════════════════════════════════════════════
let leafletMap = null;
let geojsonLayer = null;

function leafletStyle(feature) {
  const rgb = featureColor(feature);
  const isSnag     = (feature.properties?.snagCls ?? 0) > 0;
  const isViewable = is3DViewable(feature.properties?.ZTOP);
  return {
    fillColor:   `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    fillOpacity: isSnag ? 0.7 : 0.55,
    color:       isSnag ? "#f85149" : isViewable ? "#d29922" : `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    weight:      isSnag ? 2.0 : isViewable ? 2.0 : 0.8,
    opacity:     1,
  };
}

function highlightStyle(feature) {
  return {
    fillOpacity: 0.85,
    color: "#58a6ff",
    weight: 2.5,
  };
}

function initLeaflet() {
  leafletMap = L.map("map", {
    center: DEFAULT_CENTER,
    zoom:   DEFAULT_ZOOM,
    zoomControl: true,
  });

  // Pictometry 2024 aerial basemap
  L.tileLayer(PICTOMETRY_URL, {
    attribution:  "SF DPW Pictometry 2024",
    maxZoom:       22,
    maxNativeZoom: 22,
  }).addTo(leafletMap);

  // Crown polygons
  geojsonLayer = L.geoJSON(geojsonData, {
    style:        leafletStyle,
    onEachFeature: (feature, layer) => {
      const props = feature.properties || {};
      const id    = props.treeID;
      leafletLayers[id] = layer;

      layer.on("click", () => selectTree(id, "map"));
      layer.bindTooltip(buildTooltipHtml(props), {
        sticky: true,
        className: "leaflet-tooltip-dark",
      });
    },
  }).addTo(leafletMap);

  // Fit map to crowns extent
  if (geojsonLayer.getBounds().isValid()) {
    leafletMap.fitBounds(geojsonLayer.getBounds(), { padding: [20, 20] });
  }
}

function buildTooltipHtml(props) {
  const snag = (props.snagCls ?? 0) > 0
    ? `<br><b style="color:#f85149">Snag class ${props.snagCls}</b>` : "";
  return `<b>Tree ${props.treeID}</b><br>` +
         `Height: ${(props.ZTOP ?? "—")} m${snag}`;
}

// ══════════════════════════════════════════════════════════════
// SECTION 3 – Data table
// ══════════════════════════════════════════════════════════════
function initTable() {
  // Build row data from features (compute centroid lon/lat)
  tableRows = geojsonData.features.map(feature => {
    const props = feature.properties || {};
    const coords = featureCentroid(feature);
    return {
      treeID:  props.treeID  ?? "—",
      ZTOP:    props.ZTOP    ?? 0,
      snagCls: props.snagCls ?? 0,
      lat:     coords ? +coords[1].toFixed(6) : "—",
      lng:     coords ? +coords[0].toFixed(6) : "—",
      feature,
    };
  });

  // Sort headers
  document.querySelectorAll("#crown-table th.sortable").forEach(th => {
    const arrow = document.createElement("span");
    arrow.className = "sort-arrow";
    th.appendChild(arrow);
    th.addEventListener("click", () => {
      const col = th.dataset.col;
      if (sortCol === col) {
        sortDir = sortDir === "asc" ? "desc" : "asc";
      } else {
        sortCol = col;
        sortDir = col === "ZTOP" ? "desc" : "asc";
      }
      renderTable();
      updateSortHeaders();
    });
  });

  // Search
  document.getElementById("table-search").addEventListener("input", e => {
    searchQuery = e.target.value.trim().toLowerCase();
    renderTable();
  });

  updateSortHeaders();
  renderTable();
}

function featureCentroid(feature) {
  const geom = feature.geometry;
  if (!geom) return null;
  if (geom.type === "Point") return geom.coordinates;
  // Rough centroid for polygons: average of first ring
  if (geom.type === "Polygon") {
    const ring = geom.coordinates[0];
    const lon  = ring.reduce((s, c) => s + c[0], 0) / ring.length;
    const lat  = ring.reduce((s, c) => s + c[1], 0) / ring.length;
    return [lon, lat];
  }
  if (geom.type === "MultiPolygon") {
    const ring = geom.coordinates[0][0];
    const lon  = ring.reduce((s, c) => s + c[0], 0) / ring.length;
    const lat  = ring.reduce((s, c) => s + c[1], 0) / ring.length;
    return [lon, lat];
  }
  return null;
}

function renderTable() {
  let rows = tableRows;

  // Filter by search
  if (searchQuery) {
    rows = rows.filter(r =>
      String(r.treeID).toLowerCase().includes(searchQuery)
    );
  }

  // Sort
  rows = [...rows].sort((a, b) => {
    let av = a[sortCol];
    let bv = b[sortCol];
    if (typeof av === "number" && typeof bv === "number") {
      return sortDir === "asc" ? av - bv : bv - av;
    }
    return sortDir === "asc"
      ? String(av).localeCompare(String(bv))
      : String(bv).localeCompare(String(av));
  });

  document.getElementById("table-count").textContent =
    `${rows.length.toLocaleString()} / ${tableRows.length.toLocaleString()}`;

  const tbody = document.getElementById("table-body");
  tbody.innerHTML = "";

  if (rows.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" class="loading-cell">No results.</td></tr>`;
    return;
  }

  rows.forEach(row => {
    const tr = document.createElement("tr");
    if (String(row.treeID) === String(selectedId)) tr.classList.add("selected");

    const snagBadge = row.snagCls > 0
      ? `<span class="snag-badge">${row.snagCls}</span>` : "0";
    const heightFmt = typeof row.ZTOP === "number"
      ? row.ZTOP.toFixed(1) : row.ZTOP;
    const badge3d = is3DViewable(row.ZTOP)
      ? ` <span class="badge-3d">3D</span>` : "";

    tr.innerHTML =
      `<td>${row.treeID}</td>` +
      `<td>${heightFmt}${badge3d}</td>` +
      `<td>${snagBadge}</td>` +
      `<td>${row.lat}</td>` +
      `<td>${row.lng}</td>`;

    tr.addEventListener("click", () => selectTree(row.treeID, "table"));
    tbody.appendChild(tr);

    // Cache tr reference for fast selection update
    row._tr = tr;
  });

  // Store visible rows for scroll-to
  tableRows.forEach(r => { r._tr = null; });
  rows.forEach((r, idx) => {
    r._tr = tbody.querySelector(`tr:nth-child(${idx + 1})`);
  });
  const trByID = {};
  rows.forEach(r => { trByID[r.treeID] = r._tr; });
}

function updateSortHeaders() {
  document.querySelectorAll("#crown-table th.sortable").forEach(th => {
    th.classList.remove("sort-asc", "sort-desc");
    if (th.dataset.col === sortCol) {
      th.classList.add(sortDir === "asc" ? "sort-asc" : "sort-desc");
    }
  });
}

// ══════════════════════════════════════════════════════════════
// SECTION 4 – Selection (bidirectional map ↔ table)
// ══════════════════════════════════════════════════════════════
function selectTree(id, source) {
  const prevId = selectedId;
  selectedId   = String(id);

  // Restore previous Leaflet style
  if (prevId && leafletLayers[prevId]) {
    const prevFeature = geojsonData.features.find(
      f => String(f.properties?.treeID) === prevId
    );
    if (prevFeature) leafletLayers[prevId].setStyle(leafletStyle(prevFeature));
    leafletLayers[prevId].bringToBack();
  }

  // Apply highlight to new selection
  if (leafletLayers[id]) {
    leafletLayers[id].setStyle(highlightStyle());
    leafletLayers[id].bringToFront();
    if (source !== "map") {
      // Pan map to feature
      const bounds = leafletLayers[id].getBounds();
      if (bounds.isValid()) leafletMap.panTo(bounds.getCenter());
    }
  }

  // Re-render table to update highlight (fast path: toggle class)
  renderTable();

  // Scroll selected row into view
  requestAnimationFrame(() => {
    const selectedTr = document.querySelector("#crown-table tbody tr.selected");
    if (selectedTr) {
      selectedTr.scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  });

  // Update Deck.gl
  if (deckGL) renderDeckLayers();

  // Auto-activate 3D point cloud view for viewable trees
  const feature = geojsonData.features.find(
    f => String(f.properties?.treeID) === String(id)
  );
  if (feature) {
    const p = feature.properties;
    setStatus(`Selected tree ${p.treeID} — height ${p.ZTOP ?? "—"} m, snag class ${p.snagCls ?? 0}`);
    if (is3DViewable(p.ZTOP)) {
      show3D(id);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// SECTION 5 – Deck.gl 3D point cloud view
// ══════════════════════════════════════════════════════════════
const DECK_DEFAULT_VIEW = {
  longitude: DEFAULT_CENTER[1],
  latitude:  DEFAULT_CENTER[0],
  zoom:       18,
  pitch:      60,
  bearing:    0,
};

let deckInitialized  = false;
let deckHasLayers    = false;   // true once a point cloud has been rendered
let currentViewState = { ...DECK_DEFAULT_VIEW };
let treeViewState    = { ...DECK_DEFAULT_VIEW }; // initial view for the selected tree

function initDeckGL() {
  if (deckInitialized) return;
  deckInitialized = true;

  const canvas = document.getElementById("deck-canvas");
  deckGL = new deck.Deck({
    canvas,
    width:  "100%",
    height: "100%",
    controller: true,
    initialViewState: { ...DECK_DEFAULT_VIEW },
    onViewStateChange: ({ viewState: vs }) => {
      currentViewState = vs;
      deckGL.setProps({ initialViewState: vs });
    },
    layers: [],
    getCursor: ({ isDragging, isHovering }) =>
      isDragging ? "grabbing" : isHovering ? "pointer" : "grab",
  });

  document.getElementById("btn-back-to-map").addEventListener("click", showMap);

  document.getElementById("btn-reset-view").addEventListener("click", () => {
    deckGL.setProps({ initialViewState: { ...treeViewState, transitionDuration: 600 } });
  });

  document.getElementById("btn-toggle-basemap").addEventListener("click", () => {
    showBasemap = !showBasemap;
    if (deckHasLayers && selectedId) show3D(selectedId);
  });
}

// ── Native binary LAS parser (no CDN / no WASM required) ─────
// Supports LAS 1.0–1.4; reads X/Y/Z from the first 12 bytes of each point
// record (all point formats store scaled-integer X, Y, Z at the same offsets).
function parseLAS(buffer) {
  const dv = new DataView(buffer);

  // Validate "LASF" file signature
  const sig = String.fromCharCode(
    dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3)
  );
  if (sig !== "LASF") throw new Error("Not a valid LAS file (bad signature)");

  const vMinor          = dv.getUint8(25);
  const offsetToPoints  = dv.getUint32(96,  true);
  const pointRecLen     = dv.getUint16(105, true);
  // legacy 32-bit count (always populated for LAS ≤ 1.3; may be 0 for LAS 1.4)
  let   numPoints       = dv.getUint32(107, true);

  // LAS 1.4 stores the authoritative 64-bit count at offset 247
  if (vMinor >= 4 && numPoints === 0) {
    numPoints = dv.getUint32(247, true); // low 32 bits sufficient for web exports
  }

  const xScale = dv.getFloat64(131, true);
  const yScale = dv.getFloat64(139, true);
  const zScale = dv.getFloat64(147, true);
  const xOff   = dv.getFloat64(155, true);
  const yOff   = dv.getFloat64(163, true);
  const zOff   = dv.getFloat64(171, true);

  const pts = new Array(numPoints);
  let zMin = Infinity, zMax = -Infinity;

  for (let i = 0; i < numPoints; i++) {
    const base = offsetToPoints + i * pointRecLen;
    const x = dv.getInt32(base,     true) * xScale + xOff;
    const y = dv.getInt32(base + 4, true) * yScale + yOff;
    const z = dv.getInt32(base + 8, true) * zScale + zOff;
    if (z < zMin) zMin = z;
    if (z > zMax) zMax = z;
    pts[i] = { position: [x, y, z], z };
  }

  return { pts, zMin, zMax };
}

// Show 3D point cloud for a tree (called from selectTree when tree is viewable)
async function show3D(id) {
  const feature = geojsonData.features.find(
    f => String(f.properties?.treeID) === String(id)
  );
  if (!feature) return;
  const props = feature.properties;
  if (!is3DViewable(props.ZTOP)) return;

  initDeckGL();

  // Switch to 3D panel
  document.getElementById("map").classList.add("hidden");
  document.getElementById("deck-container").classList.remove("hidden");

  const loadingEl = document.getElementById("deck-loading");
  loadingEl.textContent = "Loading point cloud…";
  loadingEl.classList.remove("hidden");
  setStatus(`Loading point cloud for tree ${props.treeID}…`);

  const url = lasUrl(props.treeID);

  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status} – ${response.statusText}`);
    const buffer = await response.arrayBuffer();

    const { pts: rawPts, zMin, zMax } = parseLAS(buffer);
    const n = rawPts.length;

    // Convert local CRS XY → WGS84 lon/lat; retain Z (height above ground, metres)
    const pts = rawPts.map(p => {
      const [lon, lat] = localToLngLat(p.position[0], p.position[1]);
      return { position: [lon, lat, p.position[2]], z: p.z };
    });

    const zRange = zMax > zMin ? zMax - zMin : 1;
    const [treetopLon, treetopLat] = localToLngLat(props.XTOP, props.YTOP);

    const viewState = {
      longitude: treetopLon,
      latitude:  treetopLat,
      zoom:      18,
      pitch:     60,
      bearing:   0,
      transitionDuration: 600,
    };
    currentViewState = viewState;
    treeViewState    = viewState;

    // Update deck-legend labels with point cloud Z range
    const dMin = document.getElementById("deck-legend-min");
    const dMax = document.getElementById("deck-legend-max");
    if (dMin) dMin.textContent = zMin.toFixed(1) + " m";
    if (dMax) dMax.textContent = zMax.toFixed(1) + " m";

    const pointCloudLayer = new deck.PointCloudLayer({
      id:          "point-cloud",
      data:        pts,
      getPosition: d => d.position,
      getColor:    d => {
        const t = (d.z - zMin) / zRange;
        return [...viridisColor(t), 255];
      },
      pointSize: 3,
    });

    const layers = showBasemap
      ? [
          new deck.TileLayer({
            id:   "pictometry",
            data: PICTOMETRY_URL,
            minZoom:  0,
            maxZoom:  22,
            tileSize: 256,
            renderSubLayers: p =>
              new deck.BitmapLayer(p, {
                data:   null,
                image:  p.data,
                bounds: p.tile.boundingBox.flatMap(c => c),
              }),
          }),
          pointCloudLayer,
        ]
      : [pointCloudLayer];

    deckGL.setProps({ initialViewState: viewState, layers });
    deckHasLayers = true;
    loadingEl.classList.add("hidden");
    setStatus(`Tree ${props.treeID} — ${n.toLocaleString()} points, height ${props.ZTOP} m`);
  } catch (err) {
    loadingEl.textContent = `⚠ Could not load point cloud: ${err.message}`;
    console.error("LAS load error:", err);
    setStatus(`⚠ Point cloud unavailable for tree ${props.treeID}`);
  }
}

// Return to the 2D Leaflet map
function showMap() {
  document.getElementById("deck-container").classList.add("hidden");
  document.getElementById("map").classList.remove("hidden");
  if (leafletMap) leafletMap.invalidateSize();
}

// Stub kept so selectTree() references remain valid if deckGL isn't yet created
function renderDeckLayers() {}

// ── Boot ──────────────────────────────────────────────────────
init();
