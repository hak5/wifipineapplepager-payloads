HAKANOID LEVEL EDITOR
=====================

Create custom levels by adding level files to this folder.
Levels are 14 columns x 8 rows of bricks.

LEVEL SETS
----------
Create subdirectories for different level sets:
  levels/DEFAULT/   - Default levels
  levels/HAK5/      - Hak5 themed levels
  levels/CUSTOM/    - Your custom levels

FILE NAMING
-----------
Level files must be named: level1.txt, level2.txt, level3.txt, etc.
The game loads levels in order starting from level1.txt.

LEVEL FORMAT
------------
Bricks are separated by SPACES.

  Single char = Brick, no power-up
  Two chars   = Brick + hidden power-up
  0           = Empty space

Example: "r rL g S 0 GL"
         r  = Red brick
         rL = Red brick with hidden Laser
         g  = Green brick
         S  = Silver brick (2 hits)
         0  = Empty space
         GL = Gold brick with hidden Laser

BRICK COLORS
------------
  0 = Empty (no brick)
  x = Invisible/hidden (black - surprise!)
  r = Red
  o = Orange
  y = Yellow
  g = Green
  t = Teal
  b = Blue
  p = Purple
  m = Magenta
  w = White
  c = Chartreuse (yellow-green)
  n = Brown
  k = Pink
  l = Lime
  a = Aqua
  v = Violet
  i = Indigo
  s = Sky blue

SPECIAL BRICKS (uppercase)
--------------------------
  S = Silver (2 hits to destroy)
  G = Gold (3 hits to destroy)
  I = Indestructible (ball bounces off)

POWER-UPS (2nd character)
-------------------------
  L = Laser (shoot bricks!)
  C = Catch (sticky paddle)
  E = Expand paddle
  F = Fast ball
  S = Slow ball
  T = Tiny/shrink paddle
  R = Random power-up
  + = Extra life

EXAMPLE LEVEL (8 rows)
----------------------
# My Custom Level - comments start with #
# Each line is one row of 14 bricks

r r r r r r rL r r r r r r r
o o o o o o o o o o o o o o
y y y yE y y y y y y yE y y y
g g g g g g g g g g g g g g
t t t t t t tC t t t t t t t
b b b b b b b b b b b b b b
p p p p p p p p p p p p p p
m m m m m m m m m m m m m m

TIPS
----
- Hidden power-ups look like normal bricks until destroyed!
- Use 'x' for invisible blocks to create surprise challenges
- Silver (S) and Gold (G) bricks need multiple hits
- Indestructible (I) bricks create permanent obstacles
- Mix power-ups strategically - some help, some hurt!
- Test your levels to ensure they're beatable

POWER-UP EFFECTS
----------------
  L = Laser: Paddle shoots, press GREEN to fire (10 sec)
  C = Catch: Ball sticks to paddle once
  E = Expand: Paddle gets wider
  T = Tiny: Paddle shrinks!
  S = Slow: Ball slows down (8 sec)
  F = Fast: Ball speeds up
  + = Extra life (max 5)
  R = Random: Any of the above

Created by brAinphreAk | brainphreak.net
