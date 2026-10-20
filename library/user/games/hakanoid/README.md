# Hakanoid

Classic brick breaker arcade game for the WiFi Pineapple Pager.

## Gameplay

Break all the bricks by bouncing the ball off your paddle! Don't let the ball fall off the bottom of the screen.

## Controls

| Button | Action |
|--------|--------|
| LEFT | Move paddle left |
| RIGHT | Move paddle right |
| GREEN | Launch ball / Fire laser |
| RED | Pause menu |
| UP/DOWN | Menu navigation |

## Difficulty Levels

- **NOOB** - Slower ball speed for beginners
- **PRO** - Standard speed
- **L33T** - Fast ball for experts

## Scoring

- Normal bricks: 10 points
- Silver bricks (2 hits): 20 points
- Gold bricks (3 hits): 30 points
- Metal bricks are indestructible

## Power-Ups

Power-ups are hidden inside special bricks. When destroyed, they drop down - catch them with your paddle!

| Power-Up | Effect |
|----------|--------|
| **L** - Laser | Shoot bricks with GREEN button (10 sec) |
| **C** - Catch | Ball sticks to paddle (one use) |
| **E** - Expand | Paddle gets wider |
| **T** - Tiny | Paddle shrinks (bad!) |
| **S** - Slow | Ball slows down (8 sec) |
| **F** - Fast | Ball speeds up (bad!) |
| **+** - Extra Life | Gain an extra life (max 5) |
| **R** - Random | Any of the above |

## Level Sets

Hakanoid supports multiple level sets! Switch between them on the main menu.

- **DEFAULT** - Classic rainbow levels
- **HAK5** - Hak5 themed levels

### Creating Custom Level Sets

1. Create a new folder in `/root/payloads/user/games/hakanoid/levels/`
2. Add level files named `level1.txt`, `level2.txt`, etc.
3. Your level set will appear in the menu!

See `levels/readme.txt` for the complete level editor guide.

## Features

- **14x8 brick grid** with colorful patterns
- **Multiple brick types** - Normal, Silver, Gold, Metal, Invisible
- **8 power-ups** with various effects
- **Level set support** - switch between level packs
- **Custom level editor** - create your own levels
- **3 difficulty levels** - NOOB, PRO, L33T
- **Ball physics** - angle varies based on paddle hit position
- **High score persistence** (saved to `/root/loot/hakanoid_highscore`)
- **Sound effects** via RTTTL buzzer
- **LED effects** for game events

## Credits

- **Author**: brAinphreAk
- **Website**: [www.brainphreak.net](https://www.brainphreak.net)

## License

MIT License
