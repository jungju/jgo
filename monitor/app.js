const COLS = 10;
const ROWS = 20;
const CELL = 30;

const COLORS = {
  I: "#67e8f9",
  O: "#fde047",
  T: "#c084fc",
  S: "#86efac",
  Z: "#fda4af",
  J: "#93c5fd",
  L: "#fdba74"
};

const SHAPES = {
  I: [[1, 1, 1, 1]],
  O: [[1, 1], [1, 1]],
  T: [[0, 1, 0], [1, 1, 1]],
  S: [[0, 1, 1], [1, 1, 0]],
  Z: [[1, 1, 0], [0, 1, 1]],
  J: [[1, 0, 0], [1, 1, 1]],
  L: [[0, 0, 1], [1, 1, 1]]
};

const SCORE_PER_LINES = [0, 100, 300, 500, 800];

const boardCanvas = document.getElementById("board");
const nextCanvas = document.getElementById("next");
const boardCtx = boardCanvas.getContext("2d");
const nextCtx = nextCanvas.getContext("2d");

const scoreEl = document.getElementById("score");
const linesEl = document.getElementById("lines");
const levelEl = document.getElementById("level");
const overlayEl = document.getElementById("overlay");

const startBtn = document.getElementById("start-btn");
const pauseBtn = document.getElementById("pause-btn");
const restartBtn = document.getElementById("restart-btn");

let board = makeBoard();
let current = null;
let next = null;
let running = false;
let paused = false;
let gameOver = false;
let lastTime = 0;
let dropCounter = 0;
let score = 0;
let lines = 0;
let level = 1;

startBtn.addEventListener("click", startGame);
pauseBtn.addEventListener("click", togglePause);
restartBtn.addEventListener("click", restartGame);

document.addEventListener("keydown", handleKeydown);
document.querySelectorAll(".mobile-controls button").forEach((btn) => {
  btn.addEventListener("click", () => handleAction(btn.dataset.action));
});

showOverlay("Press Start");
draw();

function makeBoard() {
  return Array.from({ length: ROWS }, () => Array(COLS).fill(null));
}

function cloneMatrix(matrix) {
  return matrix.map((row) => row.slice());
}

function randomType() {
  const types = Object.keys(SHAPES);
  return types[Math.floor(Math.random() * types.length)];
}

function createPiece(type) {
  const matrix = cloneMatrix(SHAPES[type]);
  return {
    type,
    matrix,
    x: Math.floor((COLS - matrix[0].length) / 2),
    y: 0
  };
}

function startGame() {
  if (running && !gameOver) return;
  running = true;
  paused = false;
  gameOver = false;
  lastTime = 0;
  dropCounter = 0;
  hideOverlay();
  board = makeBoard();
  score = 0;
  lines = 0;
  level = 1;
  next = createPiece(randomType());
  spawn();
  updateStats();

  requestAnimationFrame(loop);
}

function restartGame() {
  running = false;
  paused = false;
  gameOver = false;
  lastTime = 0;
  dropCounter = 0;
  board = makeBoard();
  score = 0;
  lines = 0;
  level = 1;
  current = null;
  next = createPiece(randomType());
  spawn();
  updateStats();
  hideOverlay();
  running = true;
  requestAnimationFrame(loop);
}

function togglePause() {
  if (!running || gameOver) return;
  paused = !paused;
  if (paused) {
    showOverlay("Paused");
  } else {
    hideOverlay();
    requestAnimationFrame(loop);
  }
}

function loop(time = 0) {
  if (!running || paused || gameOver) return;
  const delta = time - lastTime;
  lastTime = time;
  dropCounter += delta;

  if (dropCounter >= dropInterval()) {
    softDrop();
    dropCounter = 0;
  }

  draw();
  requestAnimationFrame(loop);
}

function dropInterval() {
  return Math.max(90, 900 - (level - 1) * 70);
}

function spawn() {
  current = next || createPiece(randomType());
  next = createPiece(randomType());
  current.x = Math.floor((COLS - current.matrix[0].length) / 2);
  current.y = 0;

  if (collides(current)) {
    gameOver = true;
    running = false;
    showOverlay("Game Over");
  }
}

function collides(piece) {
  for (let y = 0; y < piece.matrix.length; y += 1) {
    for (let x = 0; x < piece.matrix[y].length; x += 1) {
      if (!piece.matrix[y][x]) continue;
      const nx = piece.x + x;
      const ny = piece.y + y;
      if (nx < 0 || nx >= COLS || ny >= ROWS) return true;
      if (ny >= 0 && board[ny][nx]) return true;
    }
  }
  return false;
}

function merge(piece) {
  for (let y = 0; y < piece.matrix.length; y += 1) {
    for (let x = 0; x < piece.matrix[y].length; x += 1) {
      if (!piece.matrix[y][x]) continue;
      const ny = piece.y + y;
      if (ny >= 0) {
        board[ny][piece.x + x] = piece.type;
      }
    }
  }
}

function rotateMatrix(matrix) {
  const h = matrix.length;
  const w = matrix[0].length;
  const rotated = Array.from({ length: w }, () => Array(h).fill(0));
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      rotated[x][h - 1 - y] = matrix[y][x];
    }
  }
  return rotated;
}

function clearLines() {
  let cleared = 0;
  for (let y = ROWS - 1; y >= 0; y -= 1) {
    if (board[y].every((cell) => cell)) {
      board.splice(y, 1);
      board.unshift(Array(COLS).fill(null));
      cleared += 1;
      y += 1;
    }
  }

  if (cleared > 0) {
    lines += cleared;
    score += SCORE_PER_LINES[cleared] * level;
    level = Math.floor(lines / 10) + 1;
    updateStats();
  }
}

function move(dx) {
  if (!running || paused || gameOver) return;
  current.x += dx;
  if (collides(current)) current.x -= dx;
}

function softDrop() {
  if (!running || paused || gameOver) return;
  current.y += 1;
  if (collides(current)) {
    current.y -= 1;
    merge(current);
    clearLines();
    spawn();
    updateStats();
  }
}

function hardDrop() {
  if (!running || paused || gameOver) return;
  while (!collides(current)) {
    current.y += 1;
  }
  current.y -= 1;
  merge(current);
  clearLines();
  spawn();
  updateStats();
}

function rotate() {
  if (!running || paused || gameOver) return;
  const original = current.matrix;
  const originalX = current.x;
  current.matrix = rotateMatrix(current.matrix);

  if (collides(current)) {
    current.x += 1;
    if (collides(current)) {
      current.x -= 2;
      if (collides(current)) {
        current.x = originalX;
        current.matrix = original;
      }
    }
  }
}

function handleAction(action) {
  if (action === "left") move(-1);
  if (action === "right") move(1);
  if (action === "down") softDrop();
  if (action === "rotate") rotate();
  if (action === "drop") hardDrop();
  draw();
}

function handleKeydown(event) {
  if (event.key === "p" || event.key === "P") {
    togglePause();
    return;
  }
  if (event.key === "r" || event.key === "R") {
    restartGame();
    return;
  }
  if (["ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", " "].includes(event.key)) {
    event.preventDefault();
  }
  if (event.key === "ArrowLeft") move(-1);
  if (event.key === "ArrowRight") move(1);
  if (event.key === "ArrowDown") softDrop();
  if (event.key === "ArrowUp") rotate();
  if (event.key === " ") hardDrop();
  draw();
}

function drawCell(ctx, x, y, color, size) {
  ctx.fillStyle = color;
  ctx.fillRect(x * size, y * size, size, size);
  ctx.strokeStyle = "#0f172a";
  ctx.lineWidth = 1;
  ctx.strokeRect(x * size, y * size, size, size);
}

function drawBoard() {
  boardCtx.clearRect(0, 0, boardCanvas.width, boardCanvas.height);
  boardCtx.fillStyle = "#071321";
  boardCtx.fillRect(0, 0, boardCanvas.width, boardCanvas.height);

  for (let y = 0; y < ROWS; y += 1) {
    for (let x = 0; x < COLS; x += 1) {
      const type = board[y][x];
      if (!type) continue;
      drawCell(boardCtx, x, y, COLORS[type], CELL);
    }
  }

  if (!current) return;
  for (let y = 0; y < current.matrix.length; y += 1) {
    for (let x = 0; x < current.matrix[y].length; x += 1) {
      if (!current.matrix[y][x]) continue;
      drawCell(boardCtx, current.x + x, current.y + y, COLORS[current.type], CELL);
    }
  }
}

function drawNext() {
  nextCtx.clearRect(0, 0, nextCanvas.width, nextCanvas.height);
  nextCtx.fillStyle = "#071321";
  nextCtx.fillRect(0, 0, nextCanvas.width, nextCanvas.height);
  if (!next) return;

  const matrix = next.matrix;
  const size = 24;
  const offsetX = Math.floor((nextCanvas.width - matrix[0].length * size) / 2);
  const offsetY = Math.floor((nextCanvas.height - matrix.length * size) / 2);

  for (let y = 0; y < matrix.length; y += 1) {
    for (let x = 0; x < matrix[y].length; x += 1) {
      if (!matrix[y][x]) continue;
      nextCtx.fillStyle = COLORS[next.type];
      nextCtx.fillRect(offsetX + x * size, offsetY + y * size, size, size);
      nextCtx.strokeStyle = "#0f172a";
      nextCtx.strokeRect(offsetX + x * size, offsetY + y * size, size, size);
    }
  }
}

function updateStats() {
  scoreEl.textContent = String(score);
  linesEl.textContent = String(lines);
  levelEl.textContent = String(level);
}

function showOverlay(text) {
  overlayEl.textContent = text;
  overlayEl.classList.remove("hidden");
}

function hideOverlay() {
  overlayEl.classList.add("hidden");
}

function draw() {
  drawBoard();
  drawNext();
}
