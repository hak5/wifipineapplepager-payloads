"""The on-screen keyboard for the Pager: rows like a real keyboard, moved through with the D-pad.

Green types the key under the cursor. Hold green saves. Red deletes the last character, and on an empty field it
goes back. The bottom row switches between letters, capitals and symbols, and holds space, delete and done."""

PAGES = {
    "abc": ("1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm_.@"),
    "ABC": ("1234567890", "QWERTYUIOP", "ASDFGHJKL-", "ZXCVBNM_.@"),
    "#+=": ("!\"#$%&'()*", "+,-./:;<=>", "?@[\\]^_`{|", "}~"),
}
ACTIONS = (("shift", "ABC"), ("symbols", "#+="), ("space", "space"), ("delete", "⌫"), ("done", "Done ✓"))
WIDE = {"space": 3, "done": 2}


class Keyboard:
    def __init__(self):
        self.page = "abc"
        self.row, self.col = 1, 0

    def rows(self):
        return [list(line) for line in PAGES[self.page]]

    def action_row(self):
        out = []
        for name, label in ACTIONS:
            if name == "shift":
                label = "abc" if self.page == "ABC" else "ABC"
            elif name == "symbols":
                label = "abc" if self.page == "#+=" else "#+="
            out.append((name, label))
        return out

    def height(self):
        return len(self.rows()) + 1

    def width(self, row):
        return len(self.action_row()) if row == len(self.rows()) else len(self.rows()[row])

    def move(self, name):
        rows = len(self.rows())
        if name in ("LEFT", "RIGHT"):
            self.col = (self.col + (1 if name == "RIGHT" else -1)) % self.width(self.row)
            return
        place = self.centre(self.row, self.col)
        self.row = (self.row + (1 if name == "DOWN" else -1)) % (rows + 1)
        spans = self.spans(self.row)
        self.col = min(range(len(spans)), key=lambda i: abs((spans[i][0] + spans[i][1]) / 2 - place))

    def spans(self, row):
        """Each key's left and right edge on this row, as parts of the keyboard's width."""
        if row == len(self.rows()):
            weights = [WIDE.get(name, 1) for name, _ in self.action_row()]
            total = sum(weights)
        else:
            weights = [1] * len(self.rows()[row])
            total = max(len(line) for line in self.rows())
        out, left = [], 0
        for w in weights:
            out.append((left / total, (left + w) / total))
            left += w
        return out

    def centre(self, row, col):
        left, right = self.spans(row)[col]
        return (left + right) / 2

    def current(self):
        """("char", c) or (action name, label) under the cursor."""
        if self.row == len(self.rows()):
            return self.action_row()[self.col]
        return "char", self.rows()[self.row][self.col]

    def press(self):
        """What green does here: ("type", c), ("delete",), ("done",) or None after a page switch."""
        kind, value = self.current()
        if kind == "char":
            return "type", value
        if kind == "space":
            return "type", " "
        if kind in ("delete", "done"):
            return (kind,)
        self.page = ("abc" if self.page == "ABC" else "ABC") if kind == "shift" else \
            ("abc" if self.page == "#+=" else "#+=")
        return None
