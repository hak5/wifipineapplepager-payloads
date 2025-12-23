# LED Simon Game

Simple LED-based memory game for the WiFi Pineapple Pager. Watch the color sequence, then repeat it with keyboard input to verify LED cues or just kill time between engagements.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `ROUND_LENGTH` | `5` | Number of colors to memorize. |
| `DISPLAY_DELAY` | `0.6` | Seconds each color is shown. |
| `INPUT_TIMEOUT` | `3` | Seconds to enter each guess. |

## Gameplay
1. Payload flashes a random sequence using the device LED (falls back to text if LED helper is unavailable).
2. Enter the matching colors using `r`, `g`, `b`, or `y` in order. Wrong answers blink red and end the round; success lights green.

## Notes
- Works entirely offline and does not touch radios.
- Useful as a quick LED test when the device is nearby, or as a morale booster in the field.
