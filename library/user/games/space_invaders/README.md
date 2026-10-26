# Space Invaders

Classic Space Invaders arcade game for the WiFi Pineapple Pager.

## Gameplay

Defend Earth from waves of descending alien invaders! Move your ship left and right, fire at the aliens, and use shields for cover. Don't let them reach the bottom!

## Controls

| Button | Action |
|--------|--------|
| LEFT | Move ship left |
| RIGHT | Move ship right |
| GREEN | Fire |
| RED | Pause menu |

## Scoring

- Top row aliens (cyan): 30 points
- Middle row aliens (magenta): 20 points
- Bottom row aliens (green): 10 points
- UFO (red): 100-300 points (random)

## Features

- **55 aliens** - 5 rows x 11 columns with 3 alien types
- **4 destructible shields** - pixel-by-pixel erosion from bullets and alien contact
- **Mystery UFO** - appears periodically for bonus points
- **Progressive difficulty** - aliens speed up as you destroy them, start lower each level
- **High score persistence** (saved to `/root/loot/invaders_highscore`)
- **Sound effects** via RTTTL buzzer
- **LED effects** for firing, kills, and game events
- **Player invincibility frames** after being hit
- **Smooth 20 FPS gameplay**

## Credits

- **Author**: brAinphreAk
- **Website**: [www.brainphreak.net](https://www.brainphreak.net)

## License

MIT License
