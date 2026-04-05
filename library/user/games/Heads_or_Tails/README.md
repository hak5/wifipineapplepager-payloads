# 🕶️ HEADS OR TAILS --- Terminal Coinflip Chaos

> *"Trust nothing. Not even the coin."*\
> --- spywill

------------------------------------------------------------------------

## 💀 What Is This?

**Heads or Tails** is a minimalist, terminal-driven 50/50 mind game
written in Bash.\
It looks simple.

It isn't.

Behind the scenes: - Randomized coin flips - Live spinners - Win/Loss
tracking - Confirmation gates - Dialog-based interaction - Infinite
replay loop

Built for chaos. Powered by entropy.

------------------------------------------------------------------------

## 🧠 Features

✔️ Real 50/50 coin logic using `$RANDOM`\
✔️ Interactive dialog prompts\
✔️ Spinner animation during coin flip\
✔️ Live win/loss counters\
✔️ Loop until you break\
✔️ Clean exit handling\
✔️ Color-coded logging

------------------------------------------------------------------------

## ⚙️ How It Works

``` bash
side=$(( RANDOM % 2 ))
```

The machine decides.

You choose:

\[H\] → HEADS\
\[T\] → TAILS

The script:

-   Logs your choice\
-   Spins the wheel of fate\
-   Sleeps for dramatic tension\
-   Compares destiny with delusion\
-   Updates counters\
-   Asks if you dare continue

------------------------------------------------------------------------

## 🧬 Game Flow

    [ CONFIRMATION ]
            ↓
    [ PICK HEADS / TAILS ]
            ↓
    [ SPINNER ]
            ↓
    [ RANDOM FLIP ]
            ↓
    [ WIN or LOSE ]
            ↓
    [ PLAY AGAIN? ]
            ↓
          ∞ LOOP

No mercy.\
No memory leaks.\
Just probability.

------------------------------------------------------------------------

## 📊 Counters

The script tracks:

  Variable   Meaning
  ---------- ------------
  h          HEADS wins
  t          TAILS wins
  x          Losses

Wins increment based on correct call.\
Losses stack separately.

The machine keeps score.

------------------------------------------------------------------------

## 🧨 Requirements

This script appears to rely on a Duckyscript-style dialog environment,
including functions like:

-   CONFIRMATION_DIALOG\
-   TEXT_PICKER\
-   ERROR_DIALOG\
-   PROMPT\
-   START_SPINNER\
-   STOP_SPINNER\
-   LOG\
-   WAIT_FOR_INPUT

If you're running this outside that framework, you'll need to implement
or mock those functions.

------------------------------------------------------------------------

## 🚀 Running It

``` bash
chmod +x heads_or_tails.sh
./heads_or_tails.sh
```

Then choose wisely.

------------------------------------------------------------------------

## 🕷️ Philosophy

This isn't just a coin flip.

It's:

-   A trust exercise\
-   A randomness demo\
-   A loop psychology experiment\
-   A Bash interaction showcase

Every time you press H or T, you're betting against entropy.

Entropy usually wins.

------------------------------------------------------------------------

## 🔥 Author

spywill\
Version 1.0

------------------------------------------------------------------------

## 🧾 License

Do whatever you want with it.\
But remember:

The house always wins.
