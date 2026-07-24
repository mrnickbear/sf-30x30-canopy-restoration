/* ============================================================
   SF 30×30 Canopy Restoration – app.js
   Leaflet 2D map + Deck.gl 3D view + linked data table
   ============================================================ */

// ── Configuration (mirrors config.R) ──────────────────────────
const PICTOMETRY_URL =
  "https://maps.sfdpw.org/arcgis/rest/services/Pictometry/Pictometry2024/MapServer/tile/{z}/{y}/{x}";
const CROWNS_GEOJSON       = "data/vector/crowns.geojson";
const DAN_LOST_TRAIL_KML   = "data/vector/dan-s-lost-trail.kml";
// Default map center: Laguna Honda Hospital (LHH) area, SF
const DEFAULT_CENTER  = [37.75011333486208, -122.45934823666263];
const DEFAULT_ZOOM    = 18;

const WEB_POINT_CLOUD_DIR          = "data/web_point_clouds";
const TREE_ID_PAD_WIDTH_PATH       = "data/web_point_clouds/tree_id_pad_width.txt";
const MAX_TREE_ID_PAD_WIDTH        = 4;
//let lasTreeIdPadWidth              = 1;

// PLY type name → byte width (ASPRS-style aliases also accepted)
const PLY_TYPE_SIZE = {
  char: 1, uchar: 1, short: 2, ushort: 2, int: 4, uint: 4,
  float: 4, double: 8,
  int8: 1, uint8: 1, int16: 2, uint16: 2, int32: 4, uint32: 4,
  float32: 4, float64: 8,
};

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
// Set of crown treeIDs (as strings) that have a PLY file; populated from
// crown_las_map.json at startup.  Badge display uses this instead of the
// hardcoded height threshold so it always matches the files on disk.
let viewableCrownIds = null;   // null = not yet loaded; Set once loaded

function is3DViewable(treeID) {
  if (viewableCrownIds === null) return false;
  return viewableCrownIds.has(String(treeID));
}

// Convert local LAS CRS coordinates to [longitude, latitude]
function localToLngLat(x, y) {
  return [
    LON_A * x + LON_B * y + LON_C,
    LAT_A * x + LAT_B * y + LAT_C,
  ];
}

function treeIdWidthForLas(id) {
  return id < 0 ? String(Math.abs(id)).length + 1 : String(id).length;
}

function formatTreeIdForLasFile(treeID, padWidth = MAX_TREE_ID_PAD_WIDTH) {
  const numericTreeID = Number(treeID);
  if (!Number.isInteger(numericTreeID)) return String(treeID);

  const absTreeIdStr = String(Math.abs(numericTreeID));
  if (numericTreeID < 0) {
    const absWidth = Math.max(1, padWidth - 1);
    return `-${absTreeIdStr.padStart(absWidth, "0")}`;
  }
  return absTreeIdStr.padStart(padWidth, "0");
}


async function fetchPlyBuffer(treeID, suffix = "") {
  const treeIDForFile = formatTreeIdForLasFile(treeID);
  const url = `${WEB_POINT_CLOUD_DIR}/tree_${treeIDForFile}${suffix}.ply`;
  const response = await fetch(url);
  if (response.ok) return response.arrayBuffer();
  throw new Error(`Failed to load point cloud for tree ${treeID}. ${url} -> HTTP ${response.status} - ${response.statusText}`);
}

// ── Dan's Lost Trail KML loader ───────────────────────────────
// Parses the single LineString in the KML and returns an array of
// [longitude, latitude, elevation] coordinate triples. Result is cached
// after the first successful fetch so subsequent show3D() calls are free.
let danTrailCoords = null;

async function loadDanTrail() {
  if (danTrailCoords !== null) return danTrailCoords;
  try {
    const response = await fetch(DAN_LOST_TRAIL_KML);
    if (!response.ok) return null;
    const text = await response.text();
    const parser = new DOMParser();
    const doc = parser.parseFromString(text, "application/xml");
    const coordEl = doc.querySelector("coordinates");
    if (!coordEl) return null;
    danTrailCoords = coordEl.textContent.trim().split(/\s+/).map(triplet => {
      const [lon, lat] = triplet.split(",").map(Number);
      return [lon, lat, 0];  // force z=0; KML GPS altitudes (~140 m ASL) would float above normalized-height LAS
    });
  } catch (err) {
    console.warn("Dan's Lost Trail KML could not be loaded:", err);
  }
  return danTrailCoords;
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

  // Load crown_las_map.json to know which trees have point cloud files.
  // The map is written by 04_pointcloud_web_prep.R; keys are crown treeIDs.
  // Badge display is based on this set so it always matches generated files.
  try {
    const mapRes = await fetch(`${WEB_POINT_CLOUD_DIR}/crown_las_map.json`);
    if (mapRes.ok) {
      const lasMap = await mapRes.json();
      viewableCrownIds = new Set(Object.keys(lasMap).map(String));
    }
  } catch (_) {
    // crown_las_map.json absent or unreadable — no 3D badges shown
  }
  if (viewableCrownIds === null) viewableCrownIds = new Set();

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
  const isViewable = is3DViewable(feature.properties?.treeID);
  return {
    fillColor:   `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    fillOpacity: 0.55,
    color:       isViewable ? "#7c2d12" : `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    weight:      isViewable ? 2.5 : 0.8,
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
    const badge3d = is3DViewable(row.treeID)
      ? ` <button class="badge-3d" data-tree-id="${row.treeID}" aria-label="View tree ${row.treeID} in 3D">3D</button>` : "";

    tr.innerHTML =
      `<td>${row.treeID}</td>` +
      `<td>${heightFmt}${badge3d}</td>` +
      `<td>${snagBadge}</td>` +
      `<td>${row.lat}</td>` +
      `<td>${row.lng}</td>`;

    tr.addEventListener("click", () => selectTree(row.treeID, "table"));

    // 3D button activates 3D view without re-selecting
    if (is3DViewable(row.treeID)) {
      const btn3d = tr.querySelector(".badge-3d");
      if (btn3d) {
        btn3d.addEventListener("click", (e) => {
          e.stopPropagation();
          show3D(row.treeID);
        });
      }
    }

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

  const feature = geojsonData.features.find(
    f => String(f.properties?.treeID) === String(id)
  );
  if (feature) {
    const p = feature.properties;
    setStatus(`Selected tree ${p.treeID} — height ${p.ZTOP ?? "—"} m, snag class ${p.snagCls ?? 0}`);
  }
}

// ══════════════════════════════════════════════════════════════
// SECTION 5 – Deck.gl 3D point cloud view
// ══════════════════════════════════════════════════════════════
const DECK_DEFAULT_VIEW = {
  longitude: DEFAULT_CENTER[1],
  latitude:  DEFAULT_CENTER[0],
  zoom:       18,
  pitch:       0,
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
    controller: {
      touchZoom:   true,   // pinch to zoom
      touchRotate: true,   // two-finger opposite = rotate; two-finger same direction = tilt
      inertia:     true,   // smooth deceleration after pan / tilt gestures
    },
    initialViewState: { ...DECK_DEFAULT_VIEW },
    onViewStateChange: ({ viewState: vs }) => {
      // Track current view state for the reset button only; do NOT call
      // setProps here — that would interfere with programmatic fly-to transitions.
      currentViewState = vs;
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

  const TILT_STEP  = 15;   // degrees per tap
  const PITCH_MIN  =  0;
  const PITCH_MAX  = 85;

  document.getElementById("btn-tilt-up").addEventListener("click", () => {
    const newPitch = Math.min(PITCH_MAX, (currentViewState.pitch || 0) + TILT_STEP);
    const vs = { ...currentViewState, pitch: newPitch, transitionDuration: 300 };
    currentViewState = vs;
    deckGL.setProps({ initialViewState: vs });
  });

  document.getElementById("btn-tilt-down").addEventListener("click", () => {
    const newPitch = Math.max(PITCH_MIN, (currentViewState.pitch || 0) - TILT_STEP);
    const vs = { ...currentViewState, pitch: newPitch, transitionDuration: 300 };
    currentViewState = vs;
    deckGL.setProps({ initialViewState: vs });
  });
}

// ── Native binary PLY parser (no CDN / no WASM required) ──────
// Supports binary_little_endian and binary_big_endian PLY 1.0.
// Reads all vertex properties declared in the header; extracts x/y/z
// (float32) and intensity (uint16) used by the point cloud renderer.
function parsePLY(buffer) {
  const bytes = new Uint8Array(buffer);

  // Locate end of ASCII header (terminated by "end_header\n")
  const END_HEADER = "end_header\n";
  let dataStart = -1;
  outer: for (let i = 0; i < bytes.length - END_HEADER.length; i++) {
    for (let j = 0; j < END_HEADER.length; j++) {
      if (bytes[i + j] !== END_HEADER.charCodeAt(j)) continue outer;
    }
    dataStart = i + END_HEADER.length;
    break;
  }
  if (dataStart < 0) throw new Error("Not a valid PLY file (no end_header)");

  // Parse ASCII header
  const headerText = new TextDecoder().decode(bytes.slice(0, dataStart));
  const lines = headerText.split("\n");

  let numVertices  = 0;
  let littleEndian = true;
  const properties = [];
  let inVertex = false;

  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts[0] === "format") {
      littleEndian = parts[1] !== "binary_big_endian";
    } else if (parts[0] === "element") {
      inVertex = parts[1] === "vertex";
      if (inVertex) numVertices = parseInt(parts[2], 10);
    } else if (parts[0] === "property" && parts[1] !== "list" && inVertex) {
      const type = parts[1];
      const name = parts[2];
      properties.push({ name, size: PLY_TYPE_SIZE[type] ?? 4, type });
    }
  }

  // Build per-property byte offsets within a single vertex record
  let stride = 0;
  const offsets = {};
  for (const p of properties) {
    offsets[p.name] = { offset: stride, type: p.type };
    stride += p.size;
  }

  // Read points
  const dv  = new DataView(buffer, dataStart);
  const pts = new Array(numVertices);
  let zMin  = Infinity;
  let zMax  = -Infinity;

  for (let i = 0; i < numVertices; i++) {
    const base = i * stride;
    const x = dv.getFloat32(base + offsets.x.offset, littleEndian);
    const y = dv.getFloat32(base + offsets.y.offset, littleEndian);
    const z = dv.getFloat32(base + offsets.z.offset, littleEndian);
    const intensity = offsets.intensity
      ? dv.getUint16(base + offsets.intensity.offset, littleEndian) : 0;
    if (z < zMin) zMin = z;
    if (z > zMax) zMax = z;
    pts[i] = { position: [x, y, z], z, intensity };
  }

  return { pts, zMin, zMax };
}

// Generation counter — increments on each show3D call so that a stale async
// load (from a previous tree selection) doesn't overwrite a newer one.
let show3DGeneration = 0;

// Show 3D point cloud for a tree (called from selectTree when tree is viewable).
// Loads a target PLY (selected tree's segment) and optional background PLY
// (surrounding context). Target is coloured viridis by elevation; bg is grey.
async function show3D(selectedTreeID) {
  const generation = ++show3DGeneration;

  const feature = geojsonData.features.find(
    f => String(f.properties?.treeID) === String(selectedTreeID)
  );
  if (!feature) return;
  const props = feature.properties;
  if (!is3DViewable(props.treeID)) return;

  initDeckGL();

  // Switch to 3D panel
  document.getElementById("map").classList.add("hidden");
  document.getElementById("deck-container").classList.remove("hidden");

  const loadingEl = document.getElementById("deck-loading");
  loadingEl.textContent = "Loading point cloud…";
  loadingEl.classList.remove("hidden");
  setStatus(`Loading point cloud for tree ${props.treeID}…`);

  try {
    // Fetch the target PLY (selected tree's segment only) and the optional
    // background PLY (surrounding context written by 04_pointcloud_web_prep.R).
    const [buffer, bgResult, trailCoords] = await Promise.all([
      fetchPlyBuffer(props.treeID),
      fetchPlyBuffer(props.treeID, "_bg").catch(() => null),
      loadDanTrail(),
    ]);

    // Bail out if the user has already selected a different tree
    if (generation !== show3DGeneration) return;

    const { pts: rawTargetPts, zMin, zMax } = parsePLY(buffer);
    const n = rawTargetPts.length;

    // Convert local CRS XY → WGS84 lon/lat; retain Z at true scale (no exaggeration).
    const targetPts = rawTargetPts.map(p => {
      const [lon, lat] = localToLngLat(p.position[0], p.position[1]);
      return { position: [lon, lat, p.position[2]], z: p.z, intensity: p.intensity };
    });

    // Parse background context points if the bg file was written.
    const bgPts = bgResult ? parsePLY(bgResult).pts.map(p => {
      const [lon, lat] = localToLngLat(p.position[0], p.position[1]);
      return { position: [lon, lat, p.position[2]], intensity: p.intensity };
    }) : [];

    const zRange = zMax > zMin ? zMax - zMin : 1;
    const [treetopLon, treetopLat] = localToLngLat(props.XTOP, props.YTOP);

    // Update deck-legend labels with point cloud Z range
    const dMin = document.getElementById("deck-legend-min");
    const dMax = document.getElementById("deck-legend-max");
    if (dMin) dMin.textContent = zMin.toFixed(1) + " m";
    if (dMax) dMax.textContent = zMax.toFixed(1) + " m";

    // Target tree layer: viridis colour by elevation with intensity-modulated brightness.
    const pointCloudLayer = new deck.PointCloudLayer({
      id:          "point-cloud-target",
      data:        targetPts,
      getPosition: d => d.position,
      getColor:    d => {
        // Normalise intensity (0–65535; 65535 = max uint16) to a brightness
        // factor 0.5–1.0. Falls back to 1.0 when intensity is absent / zero.
        const bright = d.intensity > 0 ? 0.5 + 0.5 * (d.intensity / 65535) : 1.0;
        const t = (d.z - zMin) / zRange;
        const rgb = viridisColor(t);
        return [
          Math.round(rgb[0] * bright),
          Math.round(rgb[1] * bright),
          Math.round(rgb[2] * bright),
          255,
        ];
      },
      pointSize: 2,
    });

    // Background context layer: dim grey, semi-transparent.
    // Rendered below the target layer so the selected tree is always visible.
    const bgLayer = bgPts.length > 0 ? new deck.PointCloudLayer({
      id:          "point-cloud-bg",
      data:        bgPts,
      getPosition: d => d.position,
      getColor:    d => {
        const bright = d.intensity > 0 ? 0.5 + 0.5 * (d.intensity / 65535) : 1.0;
        const v = Math.round(150 * bright);
        return [v, v, v, 140];
      },
      pointSize: 2,
    }) : null;

    // Dan's Lost Trail reference path layer for orientation.
    // Color matches the KML lineStyle (#ff14b446 → ABGR → green #46b414).
    const danTrailLayer = trailCoords
      ? new deck.PathLayer({
          id:            "dan-lost-trail",
          data:          [{ path: trailCoords }],
          getPath:       d => d.path,
          getColor:      [70, 180, 20, 220],
          getWidth:      2,
          widthUnits:    "pixels",
          pickable:      false,
        })
      : null;

    const baseLayers = showBasemap
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
        ]
      : [];

    const layers = [
      ...baseLayers,
      ...(danTrailLayer ? [danTrailLayer] : []),
      ...(bgLayer ? [bgLayer] : []),
      pointCloudLayer,
    ];

    // Fly to the selected tree's treetop. Using FlyToInterpolator ensures
    // the camera reliably transitions even when the 3D panel is already open
    // and the view has been manually panned.
    const viewState = {
      longitude:             treetopLon,
      latitude:              treetopLat,
      zoom:                  18,
      pitch:                 45,
      bearing:               0,
      transitionDuration:    600,
      transitionInterpolator: new deck.FlyToInterpolator(),
    };
    treeViewState = viewState;

    deckGL.setProps({ initialViewState: viewState, layers });
    deckHasLayers = true;
    loadingEl.classList.add("hidden");
    setStatus(`Tree ${props.treeID} — ${n.toLocaleString()} points, height ${props.ZTOP} m`);
  } catch (err) {
    if (generation !== show3DGeneration) return; // stale
    loadingEl.textContent = `⚠ Could not load point cloud: ${err.message}`;
    console.error("PLY load error:", err);
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
