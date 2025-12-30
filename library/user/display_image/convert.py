from PIL import Image
import struct

img = Image.open('pager.png')

# Rotate the image 90 degrees RIGHT (clockwise)
img = img.rotate(-90, expand=True)

# Now resize to 222x480
img = img.resize((222, 480))
img = img.convert('RGB')

with open('image.raw', 'wb') as f:
    for y in range(480):
        for x in range(222):
            r, g, b = img.getpixel((x, y))
            # Convert to RGB565 little-endian
            rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            f.write(struct.pack('<H', rgb565))
