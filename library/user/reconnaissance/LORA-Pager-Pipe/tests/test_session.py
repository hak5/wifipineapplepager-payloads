import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing

from lpp_test_paths import PAYLOAD_ROOT
sys.path.insert(0, str(PAYLOAD_ROOT / 'lib'))
from lpp.session import GPS, Store, create_session, atomic_json, attach, finalize


class SessionTests(unittest.TestCase):
    def test_gps_expiry_and_invalid_fix_never_emit_coordinates(self):
        gps = GPS()
        gps.update({'class':'TPV','mode':3,'lat':0.0,'lon':0.0}, now=10)
        self.assertTrue(gps.snapshot(now=15)['valid'])
        self.assertEqual(gps.snapshot(now=21)['status'], 'stale')
        self.assertNotIn('latitude', gps.snapshot(now=21))
        gps.update({'class':'TPV','mode':1,'lat':20,'lon':30}, now=25)
        self.assertFalse(gps.snapshot(now=26)['valid'])
        self.assertNotIn('latitude', gps.snapshot(now=26))

    def test_partial_tpv_does_not_erase_or_refresh_fix(self):
        gps = GPS()
        gps.update({'class':'TPV','mode':3,'lat':12,'lon':34}, now=10)
        gps.update({'class':'TPV','mode':3,'speed':1.2}, now=15)
        self.assertEqual(gps.snapshot(now=16)['age_seconds'], 6)
        self.assertTrue(gps.snapshot(now=16)['valid'])
        self.assertFalse(gps.snapshot(now=21)['valid'])

    def test_duplicate_packet_keeps_two_observations_one_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = create_session(tmp)
            store = Store(path)
            from lpp.profiles import select_profiles
            record = {'timestamp':100.0,'raw_hex':'010203','profile':select_profiles('US')[0].to_dict(),
                      'rssi_dbm':-80.0,'snr_db':2.5,'crc_ok':True,
                      'decoded':{'protocol':'meshtastic','node_id':'1234'}}
            store.append(record)
            store.append(dict(record,timestamp=102.0,rssi_dbm=-77))
            store.close()
            with closing(sqlite3.connect(path/'capture.sqlite3')) as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM observations').fetchone()[0],2)
                self.assertEqual(db.execute('SELECT sightings FROM devices').fetchone()[0],2)
            self.assertEqual(len((path/'observations.jsonl').read_text().splitlines()),2)

    def test_finalize_requires_closed_and_preserves_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = create_session(tmp)
            csv = Path(tmp)/'native.csv'
            csv.write_text('example')
            attach(path,'wifi_csv',csv)
            with self.assertRaises(ValueError): finalize(path)
            metadata = json.loads((path/'session.json').read_text())
            metadata['status']='closed'
            atomic_json(path/'session.json',metadata)
            finalize(path)
            self.assertEqual(csv.read_bytes(),(path/'wifi.csv').read_bytes())

if __name__ == '__main__': unittest.main()
