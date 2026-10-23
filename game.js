(function () {
  "use strict";

  const SIZE = 4;
  const START_TILES = 2;
  const WIN_VALUE = 2048;
  const STORAGE_BEST = "2048-best";
  const STORAGE_STATE = "2048-state";

  // --- DOM references ---
  const tileContainer = document.getElementById("tile-container");
  const gridBackground = document.getElementById("grid-background");
  const scoreEl = document.getElementById("score");
  const bestEl = document.getElementById("best");
  const messageEl = document.getElementById("game-message");
  const messageTextEl = document.getElementById("game-message-text");
  const newGameBtn = document.getElementById("new-game");
  const retryBtn = document.getElementById("retry");

  // --- State ---
  let grid = [];        // 2D array of tile objects or null
  let score = 0;
  let best = 0;
  let tileId = 0;
  let won = false;       // reached 2048
  let keepPlaying = false;
  let over = false;

  // Build the static background cells
  function buildBackground() {
    gridBackground.innerHTML = "";
    for (let i = 0; i < SIZE * SIZE; i++) {
      const cell = document.createElement("div");
      cell.className = "grid-cell";
      gridBackground.appendChild(cell);
    }
  }

  function emptyGrid() {
    const g = [];
    for (let r = 0; r < SIZE; r++) {
      g.push(new Array(SIZE).fill(null));
    }
    return g;
  }

  function newTile(value, r, c) {
    return { id: tileId++, value, r, c, isNew: true, merged: false, prev: null };
  }

  function availableCells() {
    const cells = [];
    for (let r = 0; r < SIZE; r++) {
      for (let c = 0; c < SIZE; c++) {
        if (!grid[r][c]) cells.push({ r, c });
      }
    }
    return cells;
  }

  function addRandomTile() {
    const cells = availableCells();
    if (!cells.length) return;
    const { r, c } = cells[Math.floor(Math.random() * cells.length)];
    const value = Math.random() < 0.9 ? 2 : 4;
    grid[r][c] = newTile(value, r, c);
  }

  function setupNew() {
    grid = emptyGrid();
    score = 0;
    won = false;
    keepPlaying = false;
    over = false;
    for (let i = 0; i < START_TILES; i++) addRandomTile();
    hideMessage();
    render();
    saveState();
  }

  // --- Movement helpers ---
  // Returns traversal order based on direction so we process the far side first.
  function buildTraversals(dr, dc) {
    const rows = [...Array(SIZE).keys()];
    const cols = [...Array(SIZE).keys()];
    if (dr === 1) rows.reverse();
    if (dc === 1) cols.reverse();
    return { rows, cols };
  }

  function findFarthest(r, c, dr, dc) {
    let prev = { r, c };
    let next = { r: r + dr, c: c + dc };
    while (
      next.r >= 0 && next.r < SIZE &&
      next.c >= 0 && next.c < SIZE &&
      !grid[next.r][next.c]
    ) {
      prev = next;
      next = { r: next.r + dr, c: next.c + dc };
    }
    return { farthest: prev, next };
  }

  const DIRS = {
    ArrowUp: { dr: -1, dc: 0 },
    ArrowDown: { dr: 1, dc: 0 },
    ArrowLeft: { dr: 0, dc: -1 },
    ArrowRight: { dr: 0, dc: 1 },
  };

  function move(direction) {
    if (over || (won && !keepPlaying)) return;
    const vec = DIRS[direction];
    if (!vec) return;
    const { dr, dc } = vec;

    let moved = false;

    // reset per-move flags
    for (let r = 0; r < SIZE; r++) {
      for (let c = 0; c < SIZE; c++) {
        const t = grid[r][c];
        if (t) { t.merged = false; t.isNew = false; t.prev = { r, c }; }
      }
    }

    const { rows, cols } = buildTraversals(dr, dc);

    for (const r of rows) {
      for (const c of cols) {
        const tile = grid[r][c];
        if (!tile) continue;

        const { farthest, next } = findFarthest(r, c, dr, dc);
        const nextTile = (next.r >= 0 && next.r < SIZE && next.c >= 0 && next.c < SIZE)
          ? grid[next.r][next.c]
          : null;

        if (nextTile && nextTile.value === tile.value && !nextTile.merged) {
          // Merge
          const mergedValue = tile.value * 2;
          nextTile.value = mergedValue;
          nextTile.merged = true;
          nextTile.isNew = false;
          grid[r][c] = null;
          // record where the merging tile came from (for animation it ends at nextTile cell)
          tile.r = next.r;
          tile.c = next.c;

          score += mergedValue;
          moved = true;

          if (mergedValue === WIN_VALUE && !won) {
            won = true;
          }
        } else {
          // Just move to farthest
          if (farthest.r !== r || farthest.c !== c) {
            grid[r][c] = null;
            tile.r = farthest.r;
            tile.c = farthest.c;
            grid[farthest.r][farthest.c] = tile;
            moved = true;
          }
        }
      }
    }

    if (moved) {
      addRandomTile();
      if (score > best) { best = score; saveBest(); }
      if (!movesAvailable()) {
        over = true;
      }
      render();
      saveState();
      checkEndState();
    }
  }

  function movesAvailable() {
    if (availableCells().length) return true;
    // check for possible merges
    for (let r = 0; r < SIZE; r++) {
      for (let c = 0; c < SIZE; c++) {
        const t = grid[r][c];
        if (!t) continue;
        for (const key in DIRS) {
          const { dr, dc } = DIRS[key];
          const nr = r + dr, nc = c + dc;
          if (nr >= 0 && nr < SIZE && nc >= 0 && nc < SIZE) {
            const other = grid[nr][nc];
            if (other && other.value === t.value) return true;
          }
        }
      }
    }
    return false;
  }

  function checkEndState() {
    if (won && !keepPlaying) {
      showMessage("You win!", true);
    } else if (over) {
      showMessage("Game over!", false);
    }
  }

  // --- Rendering ---
  function cellPositionStyle(tileEl, r, c) {
    // position by percentage of the container, accounting for the gap grid.
    const pct = 100 / SIZE;
    tileEl.style.width = `calc(${pct}% - var(--gap) * ${(SIZE - 1) / SIZE})`;
    tileEl.style.height = `calc(${pct}% - var(--gap) * ${(SIZE - 1) / SIZE})`;
    const x = `calc(${c} * (100% + var(--gap)) / ${SIZE})`;
    const y = `calc(${r} * (100% + var(--gap)) / ${SIZE})`;
    tileEl.style.transform = `translate(${x}, ${y})`;
  }

  function classForValue(v) {
    if (v > 2048) return "tile-super";
    return "tile-" + v;
  }

  function render() {
    tileContainer.innerHTML = "";
    for (let r = 0; r < SIZE; r++) {
      for (let c = 0; c < SIZE; c++) {
        const tile = grid[r][c];
        if (!tile) continue;
        const el = document.createElement("div");
        el.className = "tile " + classForValue(tile.value);
        el.textContent = tile.value;
        if (tile.isNew) el.classList.add("tile-new");
        if (tile.merged) el.classList.add("tile-merged");
        cellPositionStyle(el, r, c);
        tileContainer.appendChild(el);
      }
    }
    scoreEl.textContent = score;
    bestEl.textContent = best;
  }

  // --- Messages ---
  function showMessage(text, isWin) {
    messageTextEl.textContent = text;
    messageEl.classList.toggle("win", isWin);
    messageEl.classList.add("show");
    retryBtn.textContent = isWin ? "Keep playing" : "Try again";
  }

  function hideMessage() {
    messageEl.classList.remove("show", "win");
  }

  function handleRetry() {
    if (won && !keepPlaying && !over) {
      // "Keep playing" after a win
      keepPlaying = true;
      hideMessage();
      saveState();
    } else {
      setupNew();
    }
  }

  // --- Persistence ---
  function saveBest() {
    try { localStorage.setItem(STORAGE_BEST, String(best)); } catch (e) {}
  }

  function loadBest() {
    try {
      const v = parseInt(localStorage.getItem(STORAGE_BEST), 10);
      best = isNaN(v) ? 0 : v;
    } catch (e) { best = 0; }
  }

  function saveState() {
    try {
      const flat = [];
      for (let r = 0; r < SIZE; r++) {
        for (let c = 0; c < SIZE; c++) {
          flat.push(grid[r][c] ? grid[r][c].value : 0);
        }
      }
      localStorage.setItem(STORAGE_STATE, JSON.stringify({
        grid: flat, score, won, keepPlaying, over,
      }));
    } catch (e) {}
  }

  function loadState() {
    try {
      const raw = localStorage.getItem(STORAGE_STATE);
      if (!raw) return false;
      const data = JSON.parse(raw);
      if (!data || !Array.isArray(data.grid) || data.grid.length !== SIZE * SIZE) return false;
      grid = emptyGrid();
      for (let i = 0; i < data.grid.length; i++) {
        const v = data.grid[i];
        if (v) {
          const r = Math.floor(i / SIZE);
          const c = i % SIZE;
          const t = newTile(v, r, c);
          t.isNew = false;
          grid[r][c] = t;
        }
      }
      score = data.score || 0;
      won = !!data.won;
      keepPlaying = !!data.keepPlaying;
      over = !!data.over;
      return true;
    } catch (e) {
      return false;
    }
  }

  // --- Input: keyboard ---
  function onKeyDown(e) {
    if (DIRS[e.key]) {
      e.preventDefault();
      move(e.key);
    } else if (e.key === "r" || e.key === "R") {
      setupNew();
    }
  }

  // --- Input: touch / swipe ---
  let touchStart = null;
  function onTouchStart(e) {
    const t = e.touches[0];
    touchStart = { x: t.clientX, y: t.clientY };
  }
  function onTouchEnd(e) {
    if (!touchStart) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStart.x;
    const dy = t.clientY - touchStart.y;
    const absX = Math.abs(dx);
    const absY = Math.abs(dy);
    const THRESH = 20;
    if (Math.max(absX, absY) < THRESH) { touchStart = null; return; }
    if (absX > absY) {
      move(dx > 0 ? "ArrowRight" : "ArrowLeft");
    } else {
      move(dy > 0 ? "ArrowDown" : "ArrowUp");
    }
    touchStart = null;
  }

  // --- Init ---
  function init() {
    buildBackground();
    loadBest();

    if (loadState() && movesAvailable()) {
      hideMessage();
      render();
      if (over) {
        showMessage("Game over!", false);
      } else if (won && !keepPlaying) {
        showMessage("You win!", true);
      }
    } else {
      setupNew();
    }

    document.addEventListener("keydown", onKeyDown);
    const gc = document.querySelector(".game-container");
    gc.addEventListener("touchstart", onTouchStart, { passive: true });
    gc.addEventListener("touchend", onTouchEnd, { passive: true });
    newGameBtn.addEventListener("click", setupNew);
    retryBtn.addEventListener("click", handleRetry);
  }

  init();
})();
