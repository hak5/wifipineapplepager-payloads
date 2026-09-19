# The Hacker Culture Trail

_Author: [Aleff](https://github.com/aleff-github)_

## What this is

**The Hacker Culture Trail** is a small, playable tribute to hacker culture-built as a branching narrative "maze" you experience directly on a Hak5 pager device. The tone and intent are inspired by Steven Levy's *Hackers: Heroes of the Computer Revolution*: curiosity, technical elegance, playful exploration, and the idea that learning-by-doing is the real prize. 

This is not a "break things for fun" simulator. It's a guided trail through ideas, references, and small interactive moments that try to transmit the *mindset* (and a bit of the mythology) of hacker culture. The game will seem very short to you. It is brief and can be “finished” quickly, allowing you to discover all the paths by returning to the point where you had to make a choice.

The real goal is to pick up on all the messages, references, and Easter eggs scattered throughout the paths. You will need to do some research on the internet, and often you will not be sure if you have picked up on the right thing, but the important thing is to explore. You will not find answers, but starting points for those who want to delve deeper into this culture.

## Why it exists

The project was born from a simple itch: *turn the book's spirit into something you can "walk through"*. Instead of a static summary or a lecture, this payload turns concepts into choices. Each node is a short scene, a prompt, a fork in the path-so the player learns by exploring, not by being told what to think.

Goal: **an homage to Levy's book** that feels like an old-school interactive fiction trail, but delivered as a compact, hackable payload you can read, modify, and extend.

## How to play

You progress node-by-node. Each node:

* shows a chunk of text (paged if it's long),
* then offers two choices mapped to left/right inputs,
* and moves to the next node accordingly. 

Some nodes can trigger special behavior when entered (e.g., sound cues).

## Technical overview

The project is intentionally simple and moddable:

* **Core engine:** a single Bash script (`payload.sh`) runs the game loop, handles paging, reads the story graph, and resolves the next node. It runs in "strict mode" (`set -euo pipefail`) for safer behavior. 
* **Story graph:** `story/story.tsv` is a tab-separated file in the format:
 `ID<TAB>NEXT1<TAB>NEXT2`
 The engine looks up the current `node_id`, loads `NEXT1` and `NEXT2`, and then applies the player's choice. 
* **Localization:** text is stored in `locales/<lang>.lang` files (key/value). Keys are structured per node:

    * `p.<NODE_ID>.body` (main text)
    * `p.<NODE_ID>.c1` (left choice label)
    * `p.<NODE_ID>.c2` (right choice label) 
 A small `t()` helper fetches and prints values, preserving escapes, so you can include line breaks and formatting. 
* **Language selection:** at startup, the payload asks whether to continue in the other language and switches the locale file accordingly. 
* **On-enter hooks:** `on_enter_node()` can trigger special actions when a node is reached. Example: entering `SCOPRI-DEFCON` plays a ringtone using RTTTL via `RINGTONE`. 
* **UI/IO layer:** interaction is done through the device's helper functions (e.g., `PROMPT`, `WAIT_FOR_INPUT`, `CONFIRMATION_DIALOG`, `ERROR_DIALOG`). The payload assumes those primitives are available in the Hak5 environment it's meant for. 

## Repository layout

* `payload.sh` - the engine + game loop 
* `story/story.tsv` - story graph (node transitions) 
* `locales/en.lang`, `locales/it.lang` - localized node text + choices 
* `scriptbug` - one-liner helper for quick local testing / fixing line endings

## Customizing / extending

If you want to add content:

1. Add a new node ID and its two outgoing links in `story.tsv`.
2. Add `p.<ID>.body`, `p.<ID>.c1`, `p.<ID>.c2` entries in each locale file.
3. (Optional) add a hook in `on_enter_node()` for effects when the node is entered.

The engine also sanitizes CRLF and trims IDs/fields to avoid "invisible character" bugs when editing files across platforms. 

The translations have not been verified, so if you find any errors, please let me know.

---

Testing helper (from `scriptbug`):
`tr -d '\r' < payload.sh > /tmp/payload.lf && mv /tmp/payload.lf payload.sh; chmod +x payload.sh`
