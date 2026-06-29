"""
UI Components for native Pager display
Simplified from original - no PIL dependency, uses native rendering
"""

import os


class Widget:
    """Base widget class"""
    def __init__(self, xy=(0, 0), color=0):
        self.xy = xy
        self.color = color
        self.value = None

    def draw(self, display):
        """Draw widget to display (override in subclasses)"""
        pass


class Text(Widget):
    """Text widget with multi-line support and alignment"""
    def __init__(self, value="", position=(0, 0), font=None, color=0, wrap=False,
                 max_length=0, png=False, align='left', ttf_font=None, ttf_size=0):
        super().__init__(position, color)
        self.value = value
        self.font = font
        self.wrap = wrap
        self.max_length = max_length
        self.font_size = 2  # FONT_MEDIUM by default
        self.align = align  # 'left', 'center', 'right'
        self.ttf_font = ttf_font  # Path to TTF font file
        self.ttf_size = ttf_size  # TTF font size in points

    def _is_mac_address(self, word):
        """Check if word looks like a MAC address (XX:XX:XX:XX:XX:XX)"""
        # Strip trailing punctuation
        clean = word.rstrip('!.,;:')
        # MAC addresses have 5 colons and are 17 chars
        return clean.count(':') >= 4 and len(clean) >= 14

    def _wrap_text(self, text, max_chars):
        """Wrap text to multiple lines, handling long words and MAC addresses"""
        if not text or max_chars <= 0:
            return [text] if text else []

        words = str(text).split(' ')
        lines = []
        current_line = ""

        for word in words:
            # If word itself is too long, truncate it
            if len(word) > max_chars:
                word = word[:max_chars - 2] + '..'

            # MAC addresses always go on their own line
            if self._is_mac_address(word):
                if current_line:
                    lines.append(current_line)
                lines.append(word)
                current_line = ""
            elif not current_line:
                current_line = word
            elif len(current_line) + 1 + len(word) <= max_chars:
                current_line += " " + word
            else:
                lines.append(current_line)
                current_line = word

        if current_line:
            lines.append(current_line)

        return lines

    def draw(self, display):
        if self.value is not None and display:
            # Determine color:
            # - 0 = white (legacy: light text on dark background)
            # - 1 = black (legacy: dark text on light background)
            # - >1 = direct RGB565 color value
            if self.color == 0:
                color = 0xFFFF  # White
            elif self.color == 1:
                color = 0x0000  # Black
            else:
                color = self.color  # Direct RGB565 color

            # Use TTF font if specified and file exists
            if self.ttf_font and self.ttf_size > 0 and os.path.exists(self.ttf_font):
                try:
                    self._draw_ttf(display, color)
                except Exception:
                    # Fall back to bitmap on TTF error
                    self._draw_bitmap(display, color)
            else:
                self._draw_bitmap(display, color)

    def _draw_ttf(self, display, color):
        """Draw using TTF font with alignment and wrap support"""
        if self.wrap and self.max_length > 0:
            # Multi-line wrapped text
            lines = self._wrap_text(str(self.value), self.max_length)
            # Get line height from TTF
            try:
                line_height = display.ttf_height(self.ttf_font, self.ttf_size) + 2
            except:
                line_height = int(self.ttf_size * 1.2)
            y = self.xy[1]
            for line in lines:
                if self.align == 'center':
                    display.draw_ttf_centered(y, line, color, self.ttf_font, self.ttf_size)
                elif self.align == 'right':
                    display.draw_ttf_right(y, line, color, self.ttf_font, self.ttf_size, padding=5)
                else:
                    display.draw_ttf(self.xy[0], y, line, color, self.ttf_font, self.ttf_size)
                y += line_height
        else:
            # Single line
            text = str(self.value)
            if self.align == 'center':
                display.draw_ttf_centered(self.xy[1], text, color,
                                          self.ttf_font, self.ttf_size)
            elif self.align == 'right':
                display.draw_ttf_right(self.xy[1], text, color,
                                       self.ttf_font, self.ttf_size, padding=5)
            else:
                display.draw_ttf(self.xy[0], self.xy[1], text, color,
                                self.ttf_font, self.ttf_size)

    def _draw_bitmap(self, display, color):
        """Draw using built-in bitmap font"""
        if self.wrap and self.max_length > 0:
            # Multi-line wrapped text
            lines = self._wrap_text(str(self.value), self.max_length)
            line_height = 18 if self.font_size == 2 else (14 if self.font_size == 1 else 24)
            y = self.xy[1]
            for line in lines:
                if self.align == 'center':
                    display.draw_text_centered(y, line, color, self.font_size)
                elif self.align == 'right':
                    # Calculate right-aligned position
                    char_width = 10 if self.font_size == 2 else (8 if self.font_size == 1 else 12)
                    text_width = len(line) * char_width
                    screen_width = display.width if hasattr(display, 'width') else 480
                    x = screen_width - text_width - 5
                    display.draw_text(x, y, line, color, self.font_size)
                else:
                    display.draw_text(self.xy[0], y, line, color, self.font_size)
                y += line_height
        else:
            # Single line
            text = str(self.value)
            if self.align == 'center':
                display.draw_text_centered(self.xy[1], text, color, self.font_size)
            elif self.align == 'right':
                # Calculate right-aligned position
                char_width = 10 if self.font_size == 2 else (8 if self.font_size == 1 else 12)
                text_width = len(text) * char_width
                screen_width = display.width if hasattr(display, 'width') else 480
                x = screen_width - text_width - 5
                display.draw_text(x, self.xy[1], text, color, self.font_size)
            else:
                display.draw_text(self.xy[0], self.xy[1], text, color, self.font_size)


class LabeledValue(Widget):
    """Label + value widget with alignment support"""
    def __init__(self, label, value="", position=(0, 0), label_font=None, text_font=None,
                 color=0, label_spacing=5, align='left', ttf_font=None, ttf_size=0):
        super().__init__(position, color)
        self.label = label
        self.value = value
        self.label_font = label_font
        self.text_font = text_font
        self.label_spacing = label_spacing
        self.font_size = 2  # FONT_MEDIUM
        self.align = align  # 'left', 'center', 'right'
        self.ttf_font = ttf_font
        self.ttf_size = ttf_size

    def draw(self, display):
        if display:
            # Determine color (0=white, 1=black, >1=RGB565 color)
            if self.color == 0:
                color = 0xFFFF  # White
            elif self.color == 1:
                color = 0x0000  # Black
            else:
                color = self.color  # Direct RGB565 color

            text = f"{self.label}{self.value}" if self.label else str(self.value)

            # Use TTF font if specified
            if self.ttf_font and self.ttf_size > 0 and os.path.exists(self.ttf_font):
                if self.align == 'center':
                    display.draw_ttf_centered(self.xy[1], text, color,
                                              self.ttf_font, self.ttf_size)
                elif self.align == 'right':
                    display.draw_ttf_right(self.xy[1], text, color,
                                           self.ttf_font, self.ttf_size, padding=5)
                else:
                    display.draw_ttf(self.xy[0], self.xy[1], text, color,
                                    self.ttf_font, self.ttf_size)
            else:
                # Bitmap font rendering
                if self.align == 'center':
                    display.draw_text_centered(self.xy[1], text, color, self.font_size)
                elif self.align == 'right':
                    # Estimate width and adjust x position for right align
                    char_width = 10 if self.font_size == 2 else (8 if self.font_size == 1 else 12)
                    text_width = len(text) * char_width
                    screen_width = display.width if hasattr(display, 'width') else 480
                    x = screen_width - text_width - 5  # 5px padding from right
                    display.draw_text(x, self.xy[1], text, color, self.font_size)
                else:
                    if self.label:
                        display.draw_text(self.xy[0], self.xy[1], self.label, color, self.font_size)
                        label_width = len(self.label) * 10 + self.label_spacing
                        display.draw_text(self.xy[0] + label_width, self.xy[1], str(self.value), color, self.font_size)
                    else:
                        display.draw_text(self.xy[0], self.xy[1], str(self.value), color, self.font_size)


class Line(Widget):
    """Line widget"""
    def __init__(self, xy, color=0, width=1):
        super().__init__(xy, color)
        self.width = width
        self.value = True  # Always "true" for state tracking

    def draw(self, display):
        if display and len(self.xy) >= 2:
            # Determine color (0=white, 1=black, >1=RGB565 color)
            if self.color == 0:
                color = 0xFFFF  # White
            elif self.color == 1:
                color = 0x0000  # Black
            else:
                color = self.color  # Direct RGB565 color

            # xy is [(x1, y1), (x2, y2)]
            x1, y1 = self.xy[0]
            x2, y2 = self.xy[1]
            # Draw horizontal line
            if y1 == y2:
                display.hline(min(x1, x2), y1, abs(x2 - x1), color)


class Rect(Widget):
    """Rectangle outline widget"""
    def __init__(self, xy, color=0):
        super().__init__(xy, color)
        self.value = True

    def draw(self, display):
        # Not implemented for native display
        pass


class FilledRect(Widget):
    """Filled rectangle widget"""
    def __init__(self, xy, color=0):
        super().__init__(xy, color)
        self.value = True

    def draw(self, display):
        if display and len(self.xy) >= 4:
            # Determine color (0=white, 1=black, >1=RGB565 color)
            if self.color == 0:
                color = 0xFFFF  # White
            elif self.color == 1:
                color = 0x0000  # Black
            else:
                color = self.color  # Direct RGB565 color

            x, y, x2, y2 = self.xy
            display.fill_rect(x, y, x2 - x, y2 - y, color)


class Bitmap(Widget):
    """Bitmap widget - not supported on native display"""
    def __init__(self, path, xy, color=0):
        super().__init__(xy, color)
        self.path = path
        self.value = path

    def draw(self, display):
        # Bitmaps not supported on native display
        pass
