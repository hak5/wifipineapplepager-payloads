"""
Automata - basic mood system for Pagergotchi
Copied from original pwnagotchi with minimal changes (updated imports)
"""

import logging

import pwnagotchi_port.plugins as plugins
from pwnagotchi_port.ai.epoch import Epoch


class Automata(object):
    def __init__(self, config, view):
        self._config = config
        self._view = view
        self._epoch = Epoch(config)

    def _on_miss(self, who):
        logging.info("it looks like %s is not in range anymore :/", who)
        self._epoch.track(miss=True)
        # Obfuscate if privacy mode is on
        display_who = who
        if hasattr(self, '_settings') and self._settings.get('privacy_mode', False):
            from pwnagotchi_port.ui.menu import obfuscate_mac
            display_who = obfuscate_mac(who)
        self._view.on_miss(display_who)

    def _on_error(self, who, e):
        if 'is an unknown BSSID' in str(e):
            self._on_miss(who)
        else:
            logging.error(e)

    def set_starting(self):
        self._view.on_starting()

    def set_ready(self):
        plugins.on('ready', self)

    def in_good_mood(self):
        return self._has_support_network_for(1.0)

    def _has_support_network_for(self, factor):
        bond_factor = self._config['personality']['bond_encounters_factor']
        # No peers on Pager (no mesh), so always return False
        # This means we rely purely on activity for mood
        total_encounters = sum(peer.encounters for _, peer in getattr(self, '_peers', {}).items())
        support_factor = total_encounters / bond_factor
        return support_factor >= factor

    def set_grateful(self):
        self._view.on_grateful()
        plugins.on('grateful', self)

    def set_lonely(self):
        if not self._has_support_network_for(1.0):
            logging.info("unit is lonely")
            self._view.on_lonely()
            plugins.on('lonely', self)
        else:
            logging.info("unit is grateful instead of lonely")
            self.set_grateful()

    def set_bored(self):
        factor = self._epoch.inactive_for / self._config['personality']['bored_num_epochs']
        if not self._has_support_network_for(factor):
            logging.warning("%d epochs with no activity -> bored", self._epoch.inactive_for)
            self._view.on_bored()
            plugins.on('bored', self)
        else:
            logging.info("unit is grateful instead of bored")
            self.set_grateful()

    def set_sad(self):
        factor = self._epoch.inactive_for / self._config['personality']['sad_num_epochs']
        if not self._has_support_network_for(factor):
            logging.warning("%d epochs with no activity -> sad", self._epoch.inactive_for)
            self._view.on_sad()
            plugins.on('sad', self)
        else:
            logging.info("unit is grateful instead of sad")
            self.set_grateful()

    def set_angry(self, factor):
        if not self._has_support_network_for(factor):
            logging.warning("%d epochs with no activity -> angry", self._epoch.inactive_for)
            self._view.on_angry()
            plugins.on('angry', self)
        else:
            logging.info("unit is grateful instead of angry")
            self.set_grateful()

    def set_excited(self):
        logging.warning("%d epochs with activity -> excited", self._epoch.active_for)
        self._view.on_excited()
        plugins.on('excited', self)

    def set_rebooting(self):
        self._view.on_rebooting()
        plugins.on('rebooting', self)

    def wait_for(self, t, sleeping=True):
        plugins.on('sleep' if sleeping else 'wait', self, t)
        self._view.wait(t, sleeping)
        self._epoch.track(sleep=True, inc=t)

    def is_stale(self):
        return self._epoch.num_missed > self._config['personality']['max_misses_for_recon']

    def any_activity(self):
        return self._epoch.any_activity

    def set_motivated(self, reward):
        logging.info("reward %.2f -> motivated!", reward)
        self._view.on_motivated(reward)
        plugins.on('motivated', self)

    def set_demotivated(self, reward):
        logging.info("reward %.2f -> demotivated", reward)
        self._view.on_demotivated(reward)
        plugins.on('demotivated', self)

    def next_epoch(self):
        logging.debug("agent.next_epoch()")

        was_stale = self.is_stale()
        did_miss = self._epoch.num_missed
        had_activity = self._epoch.any_activity
        got_handshakes = self._epoch.did_handshakes

        self._epoch.next()

        # Get the reward calculated for this epoch
        epoch_data = self._epoch.data()
        reward = epoch_data.get('reward', 0)

        # after X misses during an epoch, set the status to lonely or angry
        if was_stale:
            factor = did_miss / self._config['personality']['max_misses_for_recon']
            if factor >= 2.0:
                self.set_angry(factor)
            else:
                logging.warning("agent missed %d interactions -> lonely", did_miss)
                self.set_lonely()
        # after X times being bored, the status is set to sad or angry
        elif self._epoch.sad_for:
            factor = self._epoch.inactive_for / self._config['personality']['sad_num_epochs']
            if factor >= 2.0:
                self.set_angry(factor)
            else:
                self.set_sad()
        # after X times being inactive, the status is set to bored
        elif self._epoch.bored_for:
            self.set_bored()
        # Got handshakes this epoch? Very motivated!
        elif got_handshakes:
            self.set_motivated(reward)
        # after X times being active, the status is set to happy / excited
        elif self._epoch.active_for >= self._config['personality']['excited_num_epochs']:
            self.set_excited()
        # Had activity with good reward? Motivated!
        elif had_activity and reward >= 5:
            self.set_motivated(reward)
        # Had activity but poor reward? Demotivated
        elif had_activity and reward < 0:
            self.set_demotivated(reward)
        elif self._epoch.active_for >= 5 and self._has_support_network_for(5.0):
            self.set_grateful()

        plugins.on('epoch', self, self._epoch.epoch - 1, self._epoch.data())

        # Check for blind epochs (no visible APs) - simplified for Pager
        if self._epoch.blind_for >= self._config['main'].get('mon_max_blind_epochs', 50):
            logging.critical("%d epochs without visible access points", self._epoch.blind_for)
            self._epoch.blind_for = 0
