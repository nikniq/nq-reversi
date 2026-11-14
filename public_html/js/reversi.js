(() => {
    'use strict';

    const N = 8, EMPTY = 0, BLACK = 1, WHITE = 2;
    const DIRS = [[-1,-1],[-1,0],[-1,1],[0,-1],[0,1],[1,-1],[1,0],[1,1]];
    // Positional weights: corners good, X/C squares next to corners bad.
    const W = [
        [120,-20, 20,  5,  5, 20,-20,120],
        [-20,-40, -5, -5, -5, -5,-40,-20],
        [ 20, -5, 15,  3,  3, 15, -5, 20],
        [  5, -5,  3,  3,  3,  3, -5,  5],
        [  5, -5,  3,  3,  3,  3, -5,  5],
        [ 20, -5, 15,  3,  3, 15, -5, 20],
        [-20,-40, -5, -5, -5, -5,-40,-20],
        [120,-20, 20,  5,  5, 20,-20,120],
    ];

    const $ = id => document.getElementById(id);
    const boardEl = $('board');
    const opp = p => (p === BLACK ? WHITE : BLACK);

    let board, turn, history, last, hints = true, busy = false, gameOver = false;
    let mode = 'ai', depth = 3;
    const cells = [];

    // ---------- Rules ----------
    function initialBoard() {
        const b = Array.from({ length: N }, () => Array(N).fill(EMPTY));
        b[3][3] = b[4][4] = WHITE;
        b[3][4] = b[4][3] = BLACK;
        return b;
    }

    function flipsFor(b, r, c, p) {
        if (b[r][c] !== EMPTY) return [];
        const o = opp(p), out = [];
        for (const [dr, dc] of DIRS) {
            const line = [];
            let y = r + dr, x = c + dc;
            while (y >= 0 && y < N && x >= 0 && x < N && b[y][x] === o) { line.push([y, x]); y += dr; x += dc; }
            if (line.length && y >= 0 && y < N && x >= 0 && x < N && b[y][x] === p) out.push(...line);
        }
        return out;
    }

    function validMoves(b, p) {
        const moves = [];
        for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
            const f = flipsFor(b, r, c, p);
            if (f.length) moves.push({ r, c, flips: f });
        }
        return moves;
    }

    function apply(b, m, p) {
        const nb = b.map(row => row.slice());
        nb[m.r][m.c] = p;
        for (const [y, x] of m.flips) nb[y][x] = p;
        return nb;
    }

    function count(b) {
        let black = 0, white = 0;
        for (const row of b) for (const v of row) { if (v === BLACK) black++; else if (v === WHITE) white++; }
        return { black, white };
    }

    // ---------- AI (minimax + alpha-beta) ----------
    function evaluate(b, me) {
        const you = opp(me);
        let pos = 0;
        for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
            if (b[r][c] === me) pos += W[r][c]; else if (b[r][c] === you) pos -= W[r][c];
        }
        const mob = validMoves(b, me).length - validMoves(b, you).length;
        return pos + mob * 6;
    }

    function minimax(b, d, alpha, beta, player, me) {
        const moves = validMoves(b, player);
        if (d === 0 || (!moves.length && !validMoves(b, opp(player)).length)) {
            if (!moves.length && !validMoves(b, opp(player)).length) {
                const s = count(b), diff = me === BLACK ? s.black - s.white : s.white - s.black;
                return diff * 1000;
            }
            return evaluate(b, me);
        }
        if (!moves.length) return minimax(b, d - 1, alpha, beta, opp(player), me);
        if (player === me) {
            let best = -Infinity;
            for (const m of moves) {
                best = Math.max(best, minimax(apply(b, m, player), d - 1, alpha, beta, opp(player), me));
                alpha = Math.max(alpha, best);
                if (alpha >= beta) break;
            }
            return best;
        }
        let best = Infinity;
        for (const m of moves) {
            best = Math.min(best, minimax(apply(b, m, player), d - 1, alpha, beta, opp(player), me));
            beta = Math.min(beta, best);
            if (alpha >= beta) break;
        }
        return best;
    }

    function bestMove(b, p) {
        const moves = validMoves(b, p);
        const empties = 64 - (count(b).black + count(b).white);
        const d = depth >= 5 && empties <= 10 ? empties : depth; // perfect endgame on hard
        let best = null, bestScore = -Infinity;
        for (const m of moves.sort(() => Math.random() - .5)) {
            const s = minimax(apply(b, m, p), d - 1, -Infinity, Infinity, opp(p), p);
            if (s > bestScore) { bestScore = s; best = m; }
        }
        return best;
    }

    // ---------- Rendering ----------
    function buildBoard() {
        boardEl.innerHTML = '';
        for (let r = 0; r < N; r++) {
            cells[r] = [];
            for (let c = 0; c < N; c++) {
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'cell';
                btn.setAttribute('role', 'gridcell');
                btn.setAttribute('aria-label', `${'ABCDEFGH'[c]}${r + 1}`);
                btn.addEventListener('click', () => humanMove(r, c));
                boardEl.appendChild(btn);
                cells[r][c] = btn;
            }
        }
    }

    function render(placed) {
        const moves = isHumanTurn() && !gameOver ? validMoves(board, turn) : [];
        const valid = new Set(moves.map(m => m.r * N + m.c));
        boardEl.classList.toggle('hints', hints);

        for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
            const el = cells[r][c], v = board[r][c];
            el.classList.toggle('valid', valid.has(r * N + c));
            el.classList.toggle('last', !!last && last.r === r && last.c === c);
            let disc = el.querySelector('.disc');
            if (v === EMPTY) { if (disc) disc.remove(); continue; }
            if (!disc) {
                disc = document.createElement('div');
                disc.className = 'disc';
                disc.innerHTML = '<div class="inner"><div class="face black"></div><div class="face white"></div></div>';
                el.appendChild(disc);
                if (placed) { disc.classList.add('placed'); }
                disc.firstChild.classList.toggle('is-white', v === WHITE);
            } else {
                disc.firstChild.classList.toggle('is-white', v === WHITE);
            }
        }

        const s = count(board);
        $('scoreBlack').textContent = s.black;
        $('scoreWhite').textContent = s.white;
        $('barBlack').style.width = `${(s.black / (s.black + s.white)) * 100}%`;
        $('pBlack').classList.toggle('active', !gameOver && turn === BLACK);
        $('pWhite').classList.toggle('active', !gameOver && turn === WHITE);
        $('undoBtn').disabled = busy || history.length === 0;
    }

    function setStatus(text, thinking = false) {
        const el = $('status');
        el.textContent = text;
        el.classList.toggle('thinking', thinking);
    }

    const nameOf = p => (mode === 'ai' ? (p === BLACK ? 'You' : 'Computer') : (p === BLACK ? 'Black' : 'White'));
    const isHumanTurn = () => mode === 'pvp' || turn === BLACK;

    // ---------- Game flow ----------
    function newGame() {
        board = initialBoard();
        turn = BLACK; history = []; last = null; gameOver = false; busy = false;
        $('modal').hidden = true;
        $('nameBlack').textContent = nameOf(BLACK);
        $('nameWhite').textContent = nameOf(WHITE);
        $('difficultyWrap').style.visibility = mode === 'ai' ? 'visible' : 'hidden';
        render(false);
        setStatus(mode === 'ai' ? 'Your move' : 'Black to move');
    }

    function play(m) {
        history.push({ board, turn, last });
        board = apply(board, m, turn);
        last = { r: m.r, c: m.c };
        turn = opp(turn);
        advance();
    }

    function advance() {
        if (!validMoves(board, turn).length) {
            if (!validMoves(board, opp(turn)).length) return endGame();
            const passer = turn;
            turn = opp(turn);
            render(true);
            setStatus(`${nameOf(passer)} must pass`);
            setTimeout(next, 1100);
            return;
        }
        render(true);
        next();
    }

    function next() {
        if (gameOver) return;
        if (isHumanTurn()) {
            busy = false;
            setStatus(mode === 'ai' ? 'Your move' : `${nameOf(turn)} to move`);
            render(false);
            return;
        }
        busy = true;
        setStatus('Thinking', true);
        render(false);
        setTimeout(() => {
            const m = bestMove(board, turn);
            busy = false;
            if (m) play(m);
        }, 450);
    }

    function humanMove(r, c) {
        if (busy || gameOver || !isHumanTurn()) return;
        const flips = flipsFor(board, r, c, turn);
        if (!flips.length) return;
        play({ r, c, flips });
    }

    function endGame() {
        gameOver = true; busy = false;
        render(true);
        const s = count(board);
        let title, icon;
        if (s.black === s.white) { title = "It's a draw"; icon = '🤝'; }
        else {
            const winner = s.black > s.white ? BLACK : WHITE;
            if (mode === 'ai') { title = winner === BLACK ? 'You win!' : 'Computer wins'; icon = winner === BLACK ? '🏆' : '🤖'; }
            else { title = `${nameOf(winner)} wins!`; icon = '🏆'; }
        }
        setStatus('Game over');
        $('modalTitle').textContent = title;
        $('modalIcon').textContent = icon;
        $('modalText').textContent = `Final score — Black ${s.black} : ${s.white} White`;
        setTimeout(() => { $('modal').hidden = false; $('againBtn').focus(); }, 700);
    }

    function undo() {
        if (busy || !history.length) return;
        // In AI mode, rewind to the last position where it was the human's turn.
        let snap = history.pop();
        while (mode === 'ai' && snap.turn !== BLACK && history.length) snap = history.pop();
        ({ board, turn, last } = snap);
        gameOver = false;
        $('modal').hidden = true;
        render(false);
        next();
    }

    // ---------- Wiring ----------
    $('newBtn').addEventListener('click', newGame);
    $('againBtn').addEventListener('click', newGame);
    $('undoBtn').addEventListener('click', undo);
    $('hintBtn').addEventListener('click', e => {
        hints = !hints;
        e.currentTarget.setAttribute('aria-pressed', String(hints));
        render(false);
    });
    $('mode').addEventListener('change', e => { mode = e.target.value; newGame(); });
    $('difficulty').addEventListener('change', e => { depth = +e.target.value; });
    document.addEventListener('keydown', e => { if (e.key === 'Escape') $('modal').hidden = true; });

    buildBoard();
    newGame();
})();
