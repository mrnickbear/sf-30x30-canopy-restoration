/* ============================================================
   SF 30×30 Canopy Restoration – app.js
   Leaflet 2D map + Deck.gl 3D point cloud + linked data table
   ============================================================ */

// ── loaders.gl: parse LAZ/LAS files in the browser ────────────
// These ESM packages match the loaders.gl version bundled in deck.gl 8.9.35.
import { parse }      from "https://cdn.jsdelivr.net/npm/@loaders.gl/core@3.3.14/+esm";
import { LASLoader }  from "https://cdn.jsdelivr.net/npm/@loaders.gl/las@3.3.14/+esm";

// ── Configuration (mirrors config.R) ──────────────────────────
const PICTOMETRY_URL =
  "https://maps.sfdpw.org/arcgis/rest/services/Pictometry/Pictometry2024/MapServer/tile/{z}/{y}/{x}";
const CROWNS_GEOJSON   = "data/vector/crowns.geojson";
const TREETOPS_GEOJSON = "data/vector/treetops.geojson";
const WEB_POINT_CLOUD_DIR          = "data/web_point_clouds";
// Mirrors WEB_POINT_CLOUD_MIN_HEIGHT_M in config.R
const WEB_POINT_CLOUD_MIN_HEIGHT_M = 42.5;
// Default map center: Laguna Honda Hospital (LHH) area, SF
const DEFAULT_CENTER = [37.75011333486208, -122.45934823666263];
const DEFAULT_ZOOM   = 18;

// ── Viridis-like 5-stop colour scale ──────────────────────────
const VIRIDIS = [
  [68,   1, 84],
  [59,  82, 139],
  [33, 145, 140],
  [94, 201, 97],
  [253, 231, 37],
];

function viridisColor(t) {
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

// ── Shared state ──────────────────────────────────────────────
let geojsonData   = null;
let heightMin     = 0;
let heightMax     = 1;
let selectedId    = null;    // currently selected treeID (string)
let leafletLayers = {};      // treeID → Leaflet layer
let tableRows     = [];      // data rows for the table
let sortCol       = "ZTOP";
let sortDir       = "desc";
let searchQuery   = "";
let deckGL        = null;
let showBasemap   = true;
let deckVisible   = false;   // true when 3D point cloud panel is shown
let currentPointCloudLayer = null;  // cached layer; reused when toggling basemap

// 3D-viewable tree state (populated after both GeoJSON files load)
let viewableIds   = new Set();  // set of string treeIDs with ZTOP > threshold
let crownPropByID = {};         // string treeID → crown properties (XTOP, YTOP, ZTOP)
let treetopByID   = {};         // string treeID → { lng, lat }
let lazMaxDigits  = 2;          // zero-padding for LAZ filenames (matches R output)

// ── Utility: normalise height value ───────────────────────────
function heightNorm(z, zMin = heightMin, zMax = heightMax) {
  if (zMax === zMin) return 0.5;
  return Math.max(0, Math.min(1, (z - zMin) / (zMax - zMin)));
}

function featureColor(feature) {
  const props = feature.properties || {};
  if (props.snagCls > 0) return [248, 81, 73];
  const z = props.ZTOP ?? 0;
  return viridisColor(heightNorm(z));
}

function isViewable(treeID) {
  return viewableIds.has(String(treeID));
}

// Generate the LAZ filename as the R pipeline does
function lazUrl(treeID) {
  return `${WEB_POINT_CLOUD_DIR}/tree_${String(treeID).padStart(lazMaxDigits, "0")}.laz`;
}

// ── Draw legend gradient on a canvas ──────────────────────────
function drawLegend(canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx  = canvas.getContext("2d");
  const grad = ctx.createLinearGradient(0, 0, canvas.width, 0);
  for (let s = 0; s <= 1; s += 0.05) {
    const rgb = viridisColor(s);
    grad.addColorStop(s, `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`);
  }
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
}

function updateLegendLabels() {
  ["legend-min"].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = heightMin.toFixed(1) + " m";
  });
  ["legend-max"].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = heightMax.toFixed(1) + " m";
  });
}

// ── Status bar helper ──────────────────────────────────────────
function setStatus(msg) {
  const el = document.getElementById("status-msg");
  if (el) el.textContent = msg;
}

// ══════════════════════════════════════════════════════════════
// SECTION 1 – Fetch GeoJSON files and boot everything
// ══════════════════════════════════════════════════════════════
async function init() {
  setStatus("Fetching crowns.geojson…");

  // Detect file:// protocol before attempting any fetch
  if (location.protocol === "file:") {
    const hint = document.createElement("span");
    hint.textContent =
      "⚠ Could not load crowns.geojson: open via a local server — e.g. ";
    const code = document.createElement("code");
    code.textContent = "python -m http.server 8080";
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

  // Load crowns.geojson
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

  // Load treetops.geojson (needed for WGS84 coordinates of each tree top)
  try {
    const res = await fetch(TREETOPS_GEOJSON);
    if (res.ok) {
      const treetops = await res.json();
      treetops.features.forEach(f => {
        const id = String(f.properties?.treeID);
        if (f.geometry?.coordinates?.length >= 2) {
          treetopByID[id] = {
            lng: f.geometry.coordinates[0],
            lat: f.geometry.coordinates[1],
          };
        }
      });
    }
  } catch (_) {
    // treetops.geojson is optional; 3D view degrades gracefully without it
  }

  // Build per-tree lookups and identify 3D-viewable trees
  geojsonData.features.forEach(f => {
    const id = String(f.properties?.treeID);
    crownPropByID[id] = f.properties;
    if ((f.properties?.ZTOP ?? 0) > WEB_POINT_CLOUD_MIN_HEIGHT_M) {
      viewableIds.add(id);
    }
  });

  // Match R's zero-padding: max digits across the viewable IDs
  if (viewableIds.size > 0) {
    lazMaxDigits = Math.max(...[...viewableIds].map(id => id.length));
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
  setStatus(`Loaded ${total.toLocaleString()} tree crowns. ` +
            `${viewableIds.size} have 3D point clouds.`);

  drawLegend("legend-canvas");
  updateLegendLabels();

  initLeaflet();
  initTable();
}

// ══════════════════════════════════════════════════════════════
// SECTION 2 – Leaflet 2D map
// ══════════════════════════════════════════════════════════════
let leafletMap   = null;
let geojsonLayer = null;

function leafletStyle(feature) {
  const rgb    = featureColor(feature);
  const isSnag = (feature.properties?.snagCls ?? 0) > 0;
  const is3D   = isViewable(feature.properties?.treeID);
  return {
    fillColor:   `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    fillOpacity: isSnag ? 0.7 : 0.55,
    // 3D-viewable → amber stroke; snag → red; others → same as fill
    color: is3D   ? "#d29922"
         : isSnag ? "#f85149"
         : `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    weight:  is3D ? 2.5 : isSnag ? 2.0 : 0.8,
    opacity: 1,
  };
}

function highlightStyle() {
  return { fillOpacity: 0.85, color: "#58a6ff", weight: 2.5 };
}

function initLeaflet() {
  leafletMap = L.map("map", {
    center:      DEFAULT_CENTER,
    zoom:        DEFAULT_ZOOM,
    zoomControl: true,
  });

  L.tileLayer(PICTOMETRY_URL, {
    attribution:   "SF DPW Pictometry 2024",
    maxZoom:        22,
    maxNativeZoom:  22,
  }).addTo(leafletMap);

  geojsonLayer = L.geoJSON(geojsonData, {
    style:         leafletStyle,
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

  if (geojsonLayer.getBounds().isValid()) {
    leafletMap.fitBounds(geojsonLayer.getBounds(), { padding: [20, 20] });
  }
}

function buildTooltipHtml(props) {
  const snag     = (props.snagCls ?? 0) > 0
    ? `<br><b style="color:#f85149">Snag class ${props.snagCls}</b>` : "";
  const viewable = isViewable(props.treeID)
    ? `<br><span style="color:#d29922">🔺 3D point cloud available</span>` : "";
  return `<b>Tree ${props.treeID}</b><br>` +
         `Height: ${(props.ZTOP ?? "—")} m${snag}${viewable}`;
}

// ══════════════════════════════════════════════════════════════
// SECTION 3 – Data table
// ══════════════════════════════════════════════════════════════
function initTable() {
  tableRows = geojsonData.features.map(feature => {
    const props  = feature.properties || {};
    const coords = featureCentroid(feature);
    return {
      treeID:   props.treeID  ?? "—",
      ZTOP:     props.ZTOP    ?? 0,
      snagCls:  props.snagCls ?? 0,
      viewable: isViewable(props.treeID),
      lat:      coords ? +coords[1].toFixed(6) : "—",
      lng:      coords ? +coords[0].toFixed(6) : "—",
      feature,
    };
  });

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

  if (searchQuery) {
    rows = rows.filter(r =>
      String(r.treeID).toLowerCase().includes(searchQuery)
    );
  }

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
    // Amber "3D" badge for trees with a point cloud export
    const badge3d = row.viewable
      ? `<span class="badge-3d">3D</span>` : "";

    tr.innerHTML =
      `<td>${row.treeID}</td>` +
      `<td>${heightFmt}${badge3d}</td>` +
      `<td>${snagBadge}</td>` +
      `<td>${row.lat}</td>` +
      `<td>${row.lng}</td>`;

    tr.addEventListener("click", () => selectTree(row.treeID, "table"));
    tbody.appendChild(tr);
  });

  // Cache tr references for scroll-to
  rows.forEach((r, idx) => {
    r._tr = tbody.querySelector(`tr:nth-child(${idx + 1})`);
  });
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

  // Highlight selected crown
  if (leafletLayers[id]) {
    leafletLayers[id].setStyle(highlightStyle());
    leafletLayers[id].bringToFront();
    if (source !== "map" && !deckVisible) {
      const bounds = leafletLayers[id].getBounds();
      if (bounds.isValid()) leafletMap.panTo(bounds.getCenter());
    }
  }

  // Re-render table
  renderTable();

  requestAnimationFrame(() => {
    const selectedTr = document.querySelector("#crown-table tbody tr.selected");
    if (selectedTr) selectedTr.scrollIntoView({ block: "nearest", behavior: "smooth" });
  });

  // Show tree info in status bar
  const feature = geojsonData.features.find(
    f => String(f.properties?.treeID) === String(id)
  );
  if (feature) {
    const p = feature.properties;
    setStatus(
      `Tree ${p.treeID} — height ${p.ZTOP ?? "—"} m` +
      (isViewable(id) ? " · 🔺 loading point cloud…" : "")
    );
  }

  // Auto-activate 3D point cloud view when a viewable tree is selected
  if (isViewable(id)) {
    showPointCloud(id);
  } else if (deckVisible) {
    // Return to map when a non-viewable tree is selected while 3D is open
    hidePointCloud();
  }
}

// ══════════════════════════════════════════════════════════════
// SECTION 5 – 3D point cloud view (Deck.gl + loaders.gl)
// ══════════════════════════════════════════════════════════════

// Show the deck panel (hide the Leaflet map)
function showDeckPanel() {
  document.getElementById("map").classList.add("hidden");
  document.getElementById("deck-container").classList.remove("hidden");
  document.getElementById("map-legend").classList.add("hidden");
  deckVisible = true;
}

// Return to the Leaflet map
function hidePointCloud() {
  document.getElementById("deck-container").classList.add("hidden");
  document.getElementById("map").classList.remove("hidden");
  document.getElementById("map-legend").classList.remove("hidden");
  deckVisible = false;

  // Re-apply selection highlight on the 2D map after returning
  if (selectedId && leafletLayers[selectedId]) {
    const bounds = leafletLayers[selectedId].getBounds();
    if (bounds && bounds.isValid()) leafletMap.panTo(bounds.getCenter());
  }
}

// Lazy-init deck.gl (created the first time a point cloud is shown)
let savedViewState = null;  // saved per-tree view state for reset

function ensureDeckGL() {
  if (deckGL) return;
  const canvas = document.getElementById("deck-canvas");
  deckGL = new deck.Deck({
    canvas,
    width:  "100%",
    height: "100%",
    controller: true,
    initialViewState: {
      longitude: DEFAULT_CENTER[1],
      latitude:  DEFAULT_CENTER[0],
      zoom:  18,
      pitch: 60,
      bearing: 0,
    },
    onViewStateChange: ({ viewState: vs }) => {
      deckGL.setProps({ initialViewState: vs });
    },
    layers: [],
    getCursor: ({ isDragging, isHovering }) =>
      isDragging ? "grabbing" : isHovering ? "pointer" : "grab",
  });

  // Controls
  document.getElementById("btn-back-to-map").addEventListener("click", () => {
    hidePointCloud();
  });
  document.getElementById("btn-reset-view").addEventListener("click", () => {
    if (deckGL && savedViewState) {
      deckGL.setProps({
        initialViewState: { ...savedViewState, transitionDuration: 600 },
      });
    }
  });
  document.getElementById("btn-toggle-basemap").addEventListener("click", () => {
    showBasemap = !showBasemap;
    if (deckGL && currentPointCloudLayer) {
      const layers = showBasemap
        ? [makeTileLayer(), currentPointCloudLayer]
        : [currentPointCloudLayer];
      deckGL.setProps({ layers });
    }
  });
}

function makeTileLayer() {
  return new deck.TileLayer({
    id:   "pictometry",
    data: PICTOMETRY_URL,
    minZoom:    0,
    maxZoom:    22,
    tileSize:   256,
    renderSubLayers: props => new deck.BitmapLayer(props, {
      data:   null,
      image:  props.data,
      bounds: props.tile.boundingBox.flatMap(c => c),
    }),
  });
}

async function showPointCloud(treeID) {
  const id = String(treeID);
  showDeckPanel();
  ensureDeckGL();

  // Show the loading overlay
  const loadingEl = document.getElementById("deck-loading");
  loadingEl.textContent = "Loading point cloud…";
  loadingEl.classList.remove("hidden");

  const crown   = crownPropByID[id];
  const treetop = treetopByID[id];

  if (!crown) {
    loadingEl.textContent = `⚠ No crown data for tree ${id}`;
    return;
  }
  if (!treetop) {
    loadingEl.textContent = `⚠ No WGS84 coordinates for tree ${id} (treetops.geojson missing?)`;
    return;
  }

  try {
    const url      = lazUrl(treeID);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status} — ${response.statusText}`);
    const buffer   = await response.arrayBuffer();
    const lazData  = await parse(buffer, LASLoader);

    const positions = lazData.attributes.POSITION.value;  // Float32Array [x0,y0,z0, ...]
    const nPoints   = positions.length / 3;

    // Compute Z range for per-tree colour normalisation
    let zMin = Infinity;
    let zMax = -Infinity;
    for (let i = 0; i < nPoints; i++) {
      const z = positions[i * 3 + 2];
      if (z < zMin) zMin = z;
      if (z > zMax) zMax = z;
    }

    // Build offset position array and pre-compute colours
    // Subtract XTOP/YTOP to convert projected coordinates to
    // metre offsets from the tree top (compatible with METER_OFFSETS).
    const offsetPos = new Float32Array(nPoints * 3);
    const colours   = new Uint8Array(nPoints * 3);
    const zRange    = zMax > zMin ? zMax - zMin : 1;

    for (let i = 0; i < nPoints; i++) {
      offsetPos[i * 3]     = positions[i * 3]     - crown.XTOP;
      offsetPos[i * 3 + 1] = positions[i * 3 + 1] - crown.YTOP;
      offsetPos[i * 3 + 2] = positions[i * 3 + 2];
      const t   = (positions[i * 3 + 2] - zMin) / zRange;
      const rgb = viridisColor(t);
      colours[i * 3]     = rgb[0];
      colours[i * 3 + 1] = rgb[1];
      colours[i * 3 + 2] = rgb[2];
    }

    // Update deck legend labels with this tree's height range
    const deckMin = document.getElementById("deck-legend-min");
    const deckMax = document.getElementById("deck-legend-max");
    if (deckMin) deckMin.textContent = zMin.toFixed(1) + " m";
    if (deckMax) deckMax.textContent = zMax.toFixed(1) + " m";
    drawLegend("deck-legend-canvas");

    currentPointCloudLayer = new deck.PointCloudLayer({
        id: "point-cloud",
        coordinateSystem: deck.COORDINATE_SYSTEM.METER_OFFSETS,
        coordinateOrigin: [treetop.lng, treetop.lat],
        data: {
          length: nPoints,
          attributes: {
            getPosition: { value: offsetPos, size: 3 },
            getColor:    { value: colours,   size: 3 },
          },
        },
        pointSize: 2,
        pickable:  false,
      });

    const targetViewState = {
        longitude:          treetop.lng,
        latitude:           treetop.lat,
        zoom:               19,
        pitch:              60,
        bearing:            0,
        transitionDuration: 800,
      };
    savedViewState = { longitude: treetop.lng, latitude: treetop.lat, zoom: 19, pitch: 60, bearing: 0 };

    const layers = [];
    if (showBasemap) layers.push(makeTileLayer());
    layers.push(currentPointCloudLayer);

    deckGL.setProps({ initialViewState: targetViewState, layers });

    loadingEl.classList.add("hidden");
    setStatus(
      `Tree ${id} — ${nPoints.toLocaleString()} pts, ` +
      `height ${crown.ZTOP} m, Z range ${zMin.toFixed(1)}–${zMax.toFixed(1)} m`
    );

  } catch (err) {
    loadingEl.textContent = `⚠ Could not load point cloud: ${err.message}`;
  }
}

// ── Boot ──────────────────────────────────────────────────────
init();
