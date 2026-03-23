# Morse Code LED & Sound Project

This project converts user-entered text into **Morse code**, playing it as a **ringtone** while simultaneously **blinking an LED** in sync. The program waits for user input to continue or exit. Perfect for microcontroller projects, hacker gadgets, or learning Morse code interactively.

## Features

- Convert text (A–Z, 0–9) to Morse code.
- Play Morse code as a **RTTTL ringtone**.
- Blink an LED in sync with Morse code dots and dashes.
- Interactive loop: continue or exit with a button press.

## How It Works

1. **Morse Dictionary**  
   Each character is mapped to its Morse code equivalent. Example: `A → .-`, `B → -...`.

2. **Text to RTTTL Conversion**  
   The `morse_to_rtttl` function converts user text into a ringtone string suitable for the `RINGTONE` function.

3. **LED Blinking**  
   The `play_led_morse` function blinks an LED in sync with dots (short) and dashes (long), including correct letter and word gaps.

4. **Main Loop**  
   - Prompts the user for a text message.  
   - Converts it to RTTTL and logs it.  
   - Plays LED blinking and ringtone simultaneously.  
   - Waits for button input to continue or exit.

## Code Usage

```bash
# Example prompt:
Enter Morse code text: HAK5 PAGER
```

The script will:
- Blink the LED with Morse code timing for each letter.
- Play the corresponding RTTTL ringtone.
- Wait for a button press to continue or exit.

## Customization

- **LED colors & durations**  
  Modify the `DOT`, `DASH`, `LETTER_GAP`, and `WORD_GAP` variables in `play_led_morse`.
- **Ringtone tempo**  
  Change the `b=` parameter in `morse_to_rtttl` for faster or slower tones.
