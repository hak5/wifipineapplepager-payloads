"""
Voice module - copied from original pwnagotchi
Provides personality phrases for different states

Modified to handle missing locale files gracefully
"""

import os
import random


class Voice:
    def __init__(self, lang='en'):
        # Try to load translations, fall back to identity function if not available
        self._ = lambda s: s  # Default: return string as-is

        try:
            import gettext
            localedir = os.path.join(os.path.abspath(os.path.dirname(__file__)), 'locale')
            if os.path.exists(localedir):
                translation = gettext.translation(
                    'voice', localedir,
                    languages=[lang],
                    fallback=True,
                )
                translation.install()
                self._ = translation.gettext
        except Exception:
            pass  # Use default identity function

    def custom(self, s):
        return s

    def default(self):
        return self._('ZzzzZZzzzzZzzz')

    def on_starting(self):
        return random.choice([
            self._('Hi, I\'m Pagergotchi! Starting ...'),
            self._('New day, new hunt, new pwns!'),
            self._('Hack the Planet!'),
            self._('No more mister Wi-Fi!!'),
            self._('Pretty fly 4 a Wi-Fi!'),
            self._('Good Pwning!'),
            self._('Free your Wi-Fi!'),
            self._('May the Wi-fi be with you'),
            self._('Pagering all networks...'),
            self._('Hak5 approved hunting!'),
            self._('Time to earn my pineapple!'),
            self._('One pager to pwn them all'),
            self._('Trust your technolust!'),
            self._('The pager awakens...'),
            self._('Pineapple power activated!'),
        ])

    def on_keys_generation(self):
        return random.choice([
            self._('Generating keys, do not turn off ...'),
            self._('Are you the keymaster?'),
            self._('I am the keymaster!'),
        ])

    def on_normal(self):
        return random.choice([
            '',
            '...'])

    def on_free_channel(self, channel):
        return self._('Hey, channel {channel} is free! Your AP will say thanks.').format(channel=channel)

    def on_reading_logs(self, lines_so_far=0):
        if lines_so_far == 0:
            return self._('Reading last session logs ...')
        return self._('Read {lines_so_far} log lines so far ...').format(lines_so_far=lines_so_far)

    def on_bored(self):
        return random.choice([
            self._('I\'m bored ...'),
            self._('Let\'s go for a walk!'),
            self._('Page me when something happens...'),
            self._('Even hackers get bored...'),
            self._('Patiently paging...'),
        ])

    def on_motivated(self, reward):
        return random.choice([
            self._('This is the best day of my life!'),
            self._('All your base are belong to us'),
            self._('Fascinating!'),
            self._('Hak5 sends their regards!'),
            self._('The pineapple is pleased!'),
            self._('Pager level: legendary!'),
        ])

    def on_demotivated(self, reward):
        return self._('Shitty day :/')

    def on_sad(self):
        return random.choice([
            self._('I\'m extremely bored ...'),
            self._('I\'m very sad ...'),
            self._('I\'m sad'),
            '...',
            self._('Even pagers have feelings...'),
            self._('Paging Mr Herman... anyone?'),
        ])

    def on_angry(self):
        return random.choice([
            '...',
            self._('Leave me alone ...'),
            self._('I\'m mad at you!')])

    def on_excited(self):
        return random.choice([
            self._('I\'m living the life!'),
            self._('I pwn therefore I am.'),
            self._('So many networks!!!'),
            self._('I\'m having so much fun!'),
            self._('My crime is that of curiosity ...'),
            self._('Pineapple power!'),
            self._('Hak5 would be proud!'),
            self._('This pager is on fire!'),
            self._('Pwning like a pineapple!'),
        ])

    def on_new_peer(self, peer):
        if peer.first_encounter():
            return random.choice([
                self._('Hello {name}! Nice to meet you.').format(name=peer.name())])
        return random.choice([
            self._('Yo {name}! Sup?').format(name=peer.name()),
            self._('Hey {name} how are you doing?').format(name=peer.name()),
            self._('Unit {name} is nearby!').format(name=peer.name())])

    def on_lost_peer(self, peer):
        return random.choice([
            self._('Uhm ... goodbye {name}').format(name=peer.name()),
            self._('{name} is gone ...').format(name=peer.name())])

    def on_miss(self, who):
        return random.choice([
            self._('Whoops ... {name} is gone.').format(name=who),
            self._('{name} missed!').format(name=who),
            self._('Missed!')])

    def on_grateful(self):
        return random.choice([
            self._('Good friends are a blessing!'),
            self._('I love my friends!')
        ])

    def on_lonely(self):
        return random.choice([
            self._('Nobody wants to play with me ...'),
            self._('I feel so alone ...'),
            self._('Let\'s find friends'),
            self._('Where\'s everybody?!'),
            self._('Is this pager thing on?'),
            self._('Paging friends... no response'),
        ])

    def on_napping(self, secs):
        return random.choice([
            self._('Napping for {secs}s ...').format(secs=secs),
            self._('Zzzzz'),
            self._('Snoring ...'),
            self._('ZzzZzzz ({secs}s)').format(secs=secs),
        ])

    def on_shutdown(self):
        return random.choice([
            self._('Good night.'),
            self._('Zzz')])

    def on_awakening(self):
        return random.choice([
            '...',
            '!',
            'Hello World!',
        ])

    def on_waiting(self, secs):
        return random.choice([
            '...',
            self._('Waiting for {secs}s ...').format(secs=secs),
            self._('Looking around ({secs}s)').format(secs=secs)])

    def on_assoc(self, ap):
        ssid, bssid = ap.get('hostname', ''), ap.get('mac', '')
        what = ssid if ssid != '' and ssid != '<hidden>' else bssid
        return random.choice([
            self._('Hey {what} let\'s be friends!').format(what=what),
            self._('Associating to {what}').format(what=what),
            self._('Yo {what}!').format(what=what),
            self._('Pagering {what}...').format(what=what),
            self._('Knock knock, {what}!').format(what=what),
        ])

    def on_deauth(self, sta):
        return random.choice([
            self._('Just decided that {mac} needs no Wi-Fi!').format(mac=sta.get('mac', '??')),
            self._('Deauthenticating {mac}').format(mac=sta.get('mac', '??')),
            self._('No more Wi-Fi for {mac}').format(mac=sta.get('mac', '??')),
            self._('Kickbanning {mac}!').format(mac=sta.get('mac', '??')),
            self._('Paging {mac}... disconnected!').format(mac=sta.get('mac', '??')),
            self._('Page denied for {mac}!').format(mac=sta.get('mac', '??')),
            self._('Return to sender, {mac}!').format(mac=sta.get('mac', '??')),
            self._('{mac} has been paged... out!').format(mac=sta.get('mac', '??')),
        ])

    def on_handshakes(self, new_shakes):
        s = 's' if new_shakes > 1 else ''
        return random.choice([
            self._('Cool, we got {num} new handshake{plural}!').format(num=new_shakes, plural=s),
            self._('Another one for the pineapple!'),
            self._('Hak5 would be proud!'),
            self._('The pager delivers!'),
            self._('Paged and pwned!'),
        ])

    def on_unread_messages(self, count, total):
        s = 's' if count > 1 else ''
        return self._('You have {count} new message{plural}!').format(count=count, plural=s)

    def on_rebooting(self):
        return random.choice([
            self._("Oops, something went wrong ... Rebooting ..."),
            self._("Have you tried turning it off and on again?"),
        ])

    def on_uploading(self, to):
        return random.choice([
            self._("Uploading data to {to} ...").format(to=to),
        ])

    def on_last_session_data(self, last_session):
        status = self._('Kicked {num} stations\n').format(num=last_session.deauthed)
        status += self._('Made {num} new friends\n').format(num=last_session.associated)
        status += self._('Got {num} handshakes\n').format(num=last_session.handshakes)
        return status

    def hhmmss(self, count, fmt):
        if count > 1:
            if fmt == "h":
                return self._("hours")
            if fmt == "m":
                return self._("minutes")
            if fmt == "s":
                return self._("seconds")
        else:
            if fmt == "h":
                return self._("hour")
            if fmt == "m":
                return self._("minute")
            if fmt == "s":
                return self._("second")
        return fmt
