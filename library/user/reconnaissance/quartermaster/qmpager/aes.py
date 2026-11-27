"""AES in counter mode in plain Python, for Meshtastic's default channel when no AES library is installed."""


def _tables():
    sbox, p, q = [0] * 256, 1, 1
    while True:
        p = p ^ (p << 1) ^ (0x1B if p & 0x80 else 0)
        p &= 0xFF
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ (q << 1 | q >> 7) ^ (q << 2 | q >> 6) ^ (q << 3 | q >> 5) ^ (q << 4 | q >> 4)
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    return sbox


SBOX = _tables()


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def expand(key):
    if len(key) not in (16, 24, 32):
        raise ValueError("key size")
    n = len(key) // 4
    rounds = n + 6
    words = [list(key[i:i + 4]) for i in range(0, len(key), 4)]
    rcon = 1
    for i in range(n, 4 * (rounds + 1)):
        t = list(words[i - 1])
        if i % n == 0:
            t = [SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = _xtime(rcon)
        elif n > 6 and i % n == 4:
            t = [SBOX[b] for b in t]
        words.append([a ^ b for a, b in zip(words[i - n], t)])
    return [sum(words[r * 4:r * 4 + 4], []) for r in range(rounds + 1)]


def encrypt_block(keys, block):
    s = [a ^ b for a, b in zip(block, keys[0])]
    last = len(keys) - 1
    for r in range(1, last + 1):
        s = [SBOX[b] for b in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if r != last:
            mixed = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                total = a[0] ^ a[1] ^ a[2] ^ a[3]
                mixed += [a[i] ^ total ^ _xtime(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = mixed
        s = [a ^ b for a, b in zip(s, keys[r])]
    return bytes(s)


def ctr(key, nonce, data):
    keys = expand(bytes(key))
    counter = int.from_bytes(nonce, "big")
    out = bytearray()
    for start in range(0, len(data), 16):
        stream = encrypt_block(keys, counter.to_bytes(16, "big"))
        out += bytes(a ^ b for a, b in zip(data[start:start + 16], stream))
        counter = (counter + 1) % (1 << 128)
    return bytes(out)
