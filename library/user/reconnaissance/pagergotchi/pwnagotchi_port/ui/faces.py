"""
Pwnagotchi faces - ASCII versions for Pager display
(Original uses Unicode which may not render correctly on all systems)
"""

# ASCII-compatible faces for the Pager display
LOOK_R = '( o_o)'
LOOK_L = '(o_o )'
LOOK_R_HAPPY = '( ^_^)'
LOOK_L_HAPPY = '(^_^ )'
SLEEP = '(-_-) zzZ'
SLEEP2 = '(-.-) zzZ'
AWAKE = '(O_O)'
BORED = '(-__-)'
INTENSE = '(0_0)'
COOL = '(B_B)'
HAPPY = '(^_^)'
GRATEFUL = '(^.^)'
EXCITED = '(*_*)'
MOTIVATED = '(>_<)'
DEMOTIVATED = '(=_=)'
SMART = '(@_@)'
LONELY = '(;_;)'
SAD = '(T_T)'
ANGRY = "(>_<')"
FRIEND = '(<3_<3)'
BROKEN = '(X_X)'
DEBUG = '(#_#)'
UPLOAD = '(1_0)'
UPLOAD1 = '(1_1)'
UPLOAD2 = '(0_1)'
PNG = False
POSITION_X = 10
POSITION_Y = 40


def load_from_config(config):
    """Load custom faces from config"""
    for face_name, face_value in config.items():
        if face_name.upper() in globals():
            globals()[face_name.upper()] = face_value
