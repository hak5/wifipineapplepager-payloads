"""A small QR code encoder: byte mode, error correction level L, versions 1 to 6 (up to 134 bytes).

Enough for the setup page address shown on the screen, with no extra packages.
"""

# version: (data codewords per block, blocks, error correction codewords per block)
_VERSIONS = {1: (19, 1, 7), 2: (34, 1, 10), 3: (55, 1, 15), 4: (80, 1, 20), 5: (108, 1, 26), 6: (68, 2, 18)}
_EXP = [0] * 512
_LOG = [0] * 256


def _tables():
    value = 1
    for power in range(255):
        _EXP[power] = value
        _LOG[value] = power
        value <<= 1
        if value & 0x100:
            value ^= 0x11D
    for power in range(255, 512):
        _EXP[power] = _EXP[power - 255]


_tables()


def _multiply(a, b):
    return 0 if not a or not b else _EXP[_LOG[a] + _LOG[b]]


def _error_correction(data, count):
    generator = [1]
    for power in range(count):
        generator = [_multiply(a, _EXP[power]) ^ b for a, b in zip(generator + [0], [0] + generator)]
    remainder = [0] * count
    for byte in data:
        factor = byte ^ remainder[0]
        remainder = remainder[1:] + [0]
        for i in range(count):
            remainder[i] ^= _multiply(generator[count - 1 - i], factor)
    return remainder


def _codewords(payload, version):
    per_block, blocks, ec_count = _VERSIONS[version]
    capacity = per_block * blocks
    bits = [0, 1, 0, 0] + [len(payload) >> i & 1 for i in range(7, -1, -1)]
    for byte in payload:
        bits += [byte >> i & 1 for i in range(7, -1, -1)]
    bits += [0] * min(4, capacity * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    data = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    data += [(0xEC, 0x11)[i % 2] for i in range(capacity - len(data))]
    chunks = [data[i * per_block:(i + 1) * per_block] for i in range(blocks)]
    checks = [_error_correction(chunk, ec_count) for chunk in chunks]
    return [chunk[i] for i in range(per_block) for chunk in chunks] + \
           [check[i] for i in range(ec_count) for check in checks]


_MASKS = (
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
)


def _penalty(grid):
    size = len(grid)
    score = 0
    lines = grid + [[grid[y][x] for y in range(size)] for x in range(size)]
    for line in lines:
        run = 1
        for i in range(1, size):
            if line[i] == line[i - 1]:
                run += 1
            else:
                score += run - 2 if run >= 5 else 0
                run = 1
        score += run - 2 if run >= 5 else 0
        text = "".join("1" if cell else "0" for cell in line)
        score += 40 * (text.count("10111010000") + text.count("00001011101"))
    for y in range(size - 1):
        for x in range(size - 1):
            if grid[y][x] == grid[y][x + 1] == grid[y + 1][x] == grid[y + 1][x + 1]:
                score += 3
    dark = sum(map(sum, grid))
    return score + 10 * (abs(dark * 20 - size * size * 10) // (size * size))


def encode(text, mask=None):
    """Return the QR code for text as rows of booleans, True for a dark module."""
    payload = text.encode("utf-8")
    version = next((v for v, (per, blocks, _) in _VERSIONS.items() if len(payload) <= per * blocks - 2), None)
    if version is None:
        raise ValueError("Too long for a QR code this size")
    size = 17 + 4 * version
    grid = [[False] * size for _ in range(size)]
    fixed = [[False] * size for _ in range(size)]

    def put(x, y, dark):
        if 0 <= x < size and 0 <= y < size:
            grid[y][x], fixed[y][x] = dark, True

    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                ring = max(abs(dx), abs(dy))
                put(cx + dx, cy + dy, ring not in (2, 4))
    if version > 1:
        center = size - 7
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                put(center + dx, center + dy, max(abs(dx), abs(dy)) != 1)
    for i in range(8, size - 8):
        put(i, 6, i % 2 == 0)
        put(6, i, i % 2 == 0)
    format_cells = [(8, i) for i in range(6)] + [(8, 7), (8, 8), (7, 8)] + [(14 - i, 8) for i in range(9, 15)]
    format_copy = [(size - 1 - i, 8) for i in range(8)] + [(8, size - 15 + i) for i in range(8, 15)]
    for x, y in format_cells + format_copy:
        put(x, y, False)
    put(8, size - 8, True)

    stream = []
    for byte in _codewords(payload, version):
        stream += [byte >> i & 1 for i in range(7, -1, -1)]
    cells, upward, right = [], True, size - 1
    while right > 0:
        if right == 6:
            right -= 1
        for y in (range(size - 1, -1, -1) if upward else range(size)):
            for x in (right, right - 1):
                if not fixed[y][x]:
                    cells.append((x, y))
        upward, right = not upward, right - 2
    for index, (x, y) in enumerate(cells):
        grid[y][x] = bool(stream[index]) if index < len(stream) else False

    def finish(pattern):
        out = [row[:] for row in grid]
        for x, y in cells:
            if _MASKS[pattern](x, y):
                out[y][x] = not out[y][x]
        info = 1 << 3 | pattern
        remainder = info
        for _ in range(10):
            remainder = remainder << 1 ^ (remainder >> 9) * 0x537
        bits = (info << 10 | remainder) ^ 0x5412
        for i in range(15):
            for x, y in (format_cells[i], format_copy[i]):
                out[y][x] = bool(bits >> i & 1)
        return out

    if mask is not None:
        return finish(mask)
    return min((finish(pattern) for pattern in range(8)), key=_penalty)


def image(text, scale=4, border=2):
    """The QR code as a black on white PIL image."""
    from PIL import Image
    grid = encode(text)
    size = len(grid)
    picture = Image.new("L", (size + 2 * border, size + 2 * border), 255)
    for y, row in enumerate(grid):
        for x, dark in enumerate(row):
            if dark:
                picture.putpixel((x + border, y + border), 0)
    return picture.resize((picture.width * scale, picture.height * scale), Image.Resampling.NEAREST).convert("RGB")
