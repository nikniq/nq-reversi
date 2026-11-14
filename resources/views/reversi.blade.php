<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="theme-color" content="#0b1020">
    <title>{{ config('app.name', 'Reversi') }} — Reversi</title>
    <link rel="preconnect" href="https://fonts.bunny.net">
    <link href="https://fonts.bunny.net/css?family=inter:400,500,600,800" rel="stylesheet">
    <link rel="stylesheet" href="{{ asset('css/reversi.css') }}?v=2">
</head>
<body>
<div class="bg-orbs" aria-hidden="true"><span></span><span></span><span></span></div>

<main class="app">
    <header class="topbar">
        <h1 class="logo">Rever<span>si</span></h1>
        <div class="controls">
            <label class="select">
                <span>Mode</span>
                <select id="mode">
                    <option value="ai" selected>vs Computer</option>
                    <option value="pvp">2 Players</option>
                </select>
            </label>
            <label class="select" id="difficultyWrap">
                <span>Level</span>
                <select id="difficulty">
                    <option value="1">Easy</option>
                    <option value="3" selected>Medium</option>
                    <option value="5">Hard</option>
                </select>
            </label>
        </div>
        <nav class="account">
            @auth
                @if (auth()->user()->avatar)
                    <img src="{{ auth()->user()->avatar }}" alt="" class="avatar" referrerpolicy="no-referrer">
                @endif
                <span class="who">{{ auth()->user()->name }}</span>
                <form method="POST" action="{{ route('logout') }}">@csrf<button class="btn small" type="submit">Log out</button></form>
            @else
                <a href="{{ route('login') }}" class="btn small">Log in</a>
                <a href="{{ route('register') }}" class="btn small primary">Sign up</a>
            @endauth
        </nav>
    </header>

    <section class="scoreboard">
        <div class="player" id="pBlack">
            <div class="chip black"></div>
            <div><div class="pname" id="nameBlack">You</div><div class="pscore" id="scoreBlack">2</div></div>
        </div>
        <div class="status" id="status" aria-live="polite">Your move</div>
        <div class="player right" id="pWhite">
            <div><div class="pname" id="nameWhite">Computer</div><div class="pscore" id="scoreWhite">2</div></div>
            <div class="chip white"></div>
        </div>
    </section>

    <div class="progress" aria-hidden="true"><div id="barBlack"></div></div>

    <section class="board-wrap">
        <div class="board" id="board" role="grid" aria-label="Reversi board"></div>
    </section>

    <footer class="actions">
        <button class="btn" id="undoBtn" type="button">↶ Undo</button>
        <button class="btn" id="hintBtn" type="button" aria-pressed="true">◎ Hints</button>
        <button class="btn primary" id="newBtn" type="button">New game</button>
    </footer>
</main>

<div class="modal" id="modal" hidden>
    <div class="card">
        <div class="trophy" id="modalIcon">🏆</div>
        <h2 id="modalTitle">You win!</h2>
        <p id="modalText"></p>
        <button class="btn primary" id="againBtn" type="button">Play again</button>
    </div>
</div>

<script src="{{ asset('js/reversi.js') }}?v=1"></script>
</body>
</html>
