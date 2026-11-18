import importlib.util, json, pathlib, struct, tempfile, unittest
from unittest import mock

PATH=pathlib.Path(__file__).with_name("c5_pager_node.py")
spec=importlib.util.spec_from_file_location("node",PATH); node=importlib.util.module_from_spec(spec); spec.loader.exec_module(node)

class PayloadTests(unittest.TestCase):
    def test_payload_exposes_mmc_python_packages(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn("PYTHON_MMCLIB",payload)
        self.assertIn("CONFIRMATION_DIALOG",payload)
        self.assertIn("opkg -d mmc --force-reinstall install python3-light",payload)
        self.assertIn("Requires internet and persistent storage changes",payload)
        self.assertIn('/mmc/usr/bin',payload)
        self.assertIn('LD_LIBRARY_PATH',payload)
        self.assertIn('return 2',payload)
        self.assertIn('--self-check',payload)
        self.assertLess(payload.index("export PYTHONPATH"), payload.index('"$DIR/c5_pager_node.py" --self-check'))
        self.assertNotIn("$(python3 ",payload)
        self.assertNotIn("< <(python3 ",payload)
        self.assertNotIn("\n  python3 ",payload)
    def test_payload_supports_explicit_on_device_pairing(self):
        payload=PATH.with_name("payload.sh").read_text()
        for expected in ("LIST_PICKER","MAC_PICKER","PAYLOAD_GET_CONFIG","PAYLOAD_SET_CONFIG","--discover-seconds 6","Pair with $CORE_MAC?"):
            self.assertIn(expected,payload)
        self.assertIn("CANDIDATES",payload)
        self.assertLess(payload.index("CONFIRMATION_DIALOG"),payload.index("save_core",payload.index("Pair nearby Core")))
    def test_payload_supervises_worker_until_button_stop(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn("while true; do",payload)
        self.assertIn("Node worker stopped; restarting...",payload)
        self.assertIn("start_worker",payload)
    def test_payload_uses_transient_pineap_radio_control_and_restores_state(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn('_pineap INTERFACE LIST format=json',payload)
        self.assertIn('_pineap INTERFACE SET "$IFACE" CHANNEL 6',payload)
        self.assertIn('HOP fast',payload)
        self.assertIn('HOP slow',payload)
        self.assertIn('CHANNEL "$OLD_CHANNEL"',payload)
        self.assertNotIn('uci set pineapd',payload)
        self.assertNotIn('/etc/init.d/pineapd restart',payload)
    def test_payload_handles_confirmation_and_signals_per_pager_api(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn('DUCKYSCRIPT_USER_CONFIRMED',payload)
        self.assertIn("trap cleanup EXIT",payload)
        self.assertIn("trap 'exit 0' INT TERM",payload)
    def test_payload_cats_atomic_worker_status_and_bounds_logging(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn('status=$(cat "$STATUS")',payload)
        self.assertIn('now-LAST_LOG_TIME',payload)
        self.assertIn('-ge 10',payload)
        self.assertIn('-ge 30',payload)
        self.assertNotIn('--render-stats',payload)
    def test_splash_is_pager_sized_title_card(self):
        data=PATH.with_name("splash.png").read_bytes()
        self.assertEqual(data[:8],b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II",data[16:24]),(480,222))

    def test_worker_self_check(self):
        self.assertEqual(node.main(["--self-check"]), 0)

class ProtocolTests(unittest.TestCase):
    @staticmethod
    def rsn_frame(akm_types,pairwise_type=4):
        frame=bytearray(36); frame[34]=0x10
        selector=lambda kind: b"\x00\x0f\xac"+bytes([kind])
        body=b"\x01\x00"+selector(4)+struct.pack("<H",1)+selector(pairwise_type)+struct.pack("<H",len(akm_types))+b"".join(selector(kind) for kind in akm_types)
        return bytes(frame)+bytes([48,len(body)])+body

    def test_text_message_matches_c5_struct(self):
        msg=node.text_message(node.TEXT,7,b"hello")
        self.assertEqual(len(msg),212)
        self.assertEqual(node.parse_text_message(msg),(node.TEXT,7,b"hello"))
    def test_record_ack_round_trip(self):
        msg=node.text_message(node.RECORD_ACK,19,b"W6,5975")
        self.assertEqual(node.parse_text_message(msg),(node.RECORD_ACK,19,b"W6,5975"))
    def test_external_6ghz_capability_round_trip(self):
        for kind in (node.CORE_REQUEST,node.HEARTBEAT):
            msg=node.text_message(kind,7,node.CAPABILITIES)
            self.assertEqual(node.parse_text_message(msg),(kind,7,node.CAPABILITIES))
    def test_ack_client_requires_matching_detail_and_bounds_drain(self):
        source=PATH.read_text()
        self.assertIn("parsed[2]==expected_ack",source)
        self.assertIn("drain_deadline=time.monotonic()+.5",source)
        self.assertIn("count<3",source)
        self.assertIn("os.urandom(4)",source)
        self.assertIn('if not a.core: ap.error("--core is required")',source)
        self.assertIn("src!=wanted",source)
        self.assertIn('IW_BIN=os.environ.get("IW_BIN","/usr/sbin/iw")',source)
        self.assertIn("subprocess.run([IW_BIN",source)
        self.assertIn("text_message(CORE_REQUEST,text=CAPABILITIES)",source)
        self.assertIn("text_message(HEARTBEAT,heartbeat,CAPABILITIES)",source)
        self.assertIn("for kind,item in radio.receive(.15):",source)
        self.assertIn("CORE_LINK_TIMEOUT=15.0",source)
        self.assertIn("PSC_DWELL=.20",source)
    def test_payload_uses_portable_core_mac_parser(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn("open(sys.argv[1]).read().strip()",payload)
        self.assertNotIn("tr -d '[:space:]'",payload)
        self.assertIn("[0-9A-Fa-f]",payload)
        self.assertIn("LAUNCH_DIR=",payload)
        self.assertIn("/root/payloads/user/reconnaissance/c5_wardriver_node/c5_pager_node.py",payload)
        self.assertIn("/mmc/root/payloads/user/reconnaissance/c5_wardriver_node/c5_pager_node.py",payload)
    def test_core_discovery_deduplicates_valid_replies(self):
        core=bytes.fromhex("3cdc7586de94")
        class FakeRadio:
            def __init__(self): self.sent=[]
            def send(self,dst,payload): self.sent.append((dst,payload)); return True
            def receive(self,seconds):
                yield "message",(core,node.text_message(node.CORE_REPLY))
                yield "message",(core,node.text_message(node.CORE_REPLY))
                yield "message",(b"\x01"*6,node.text_message(node.HEARTBEAT))
        radio=FakeRadio()
        with mock.patch.object(node.time,"monotonic",side_effect=[0,0,2]), mock.patch.object(node,"tune",return_value=True):
            self.assertEqual(node.discover_cores(radio,"wlan1mon",1),[core])
        self.assertEqual(radio.sent[0][0],node.BROADCAST)
        self.assertEqual(node.parse_text_message(radio.sent[0][1]),(node.CORE_REQUEST,0,node.CAPABILITIES))
    def test_live_status_metrics(self):
        status=node.format_status({"core":"3c:dc:75:86:de:94","seen":12,"queued":3,"sent":10,"acked":9,"dropped":1,"latest":{"ssid":"Pager Test","channel":5,"rssi":-42}})
        for expected in ("CORE: LINKED","NET: Pager Test","CH: 5  RSSI: -42 dBm","SEEN: 12  QUEUE: 3","TX: 10  ACK: 9  DROP: 1","A: STOP"):
            self.assertIn(expected,status)
    def test_status_sanitizes_and_bounds_ssid(self):
        status=node.format_status({"latest":{"ssid":"A\nB"+"X"*30}})
        self.assertNotIn("A\nB",status)
        self.assertIn("CORE: SEARCH",status)
        self.assertLessEqual(len(status.splitlines()[1].removeprefix("NET: ")),22)
    def test_rsn_security_uses_only_akm_list(self):
        self.assertEqual(node.security(self.rsn_frame([2],pairwise_type=8)),"[WPA2_PSK]")
        self.assertEqual(node.security(self.rsn_frame([8])),"[WPA3_PSK]")
        self.assertEqual(node.security(self.rsn_frame([24])),"[WPA3_PSK]")
        self.assertEqual(node.security(self.rsn_frame([12])),"[WPA3_ENTERPRISE]")
        self.assertEqual(node.security(self.rsn_frame([18])),"[OWE]")
    def test_malformed_rsn_is_undefined(self):
        frame=bytearray(36); frame[34]=0x10
        self.assertEqual(node.security(bytes(frame)+b"\x30\x02\x01\x00"),"[UNDEFINED]")
    def test_core_link_timeout_boundary(self):
        self.assertFalse(node.link_expired(None,999))
        self.assertFalse(node.link_expired(10,10+node.CORE_LINK_TIMEOUT-.01))
        self.assertTrue(node.link_expired(10,10+node.CORE_LINK_TIMEOUT))
    def test_interface_state_parser_preserves_hoprate_and_channel(self):
        data={"interfaces":[{"interface":"wlan0","hoprate":0,"channel":1},{"interface":"wlan1mon","hoprate":200,"channel":44}]}
        self.assertEqual(node.interface_state(data,"wlan1mon"),(200,44))
        self.assertEqual(node.interface_state({"wlan1mon":{"hoprate":0,"channel":6}},"wlan1mon"),(0,6))
        self.assertEqual(node.interface_state([{"ifname":"wlan1mon","hoprate":1000,"channel":11}],"wlan1mon"),(1000,11))
        self.assertEqual(node.interface_state([{"ifname":"wlan1mon","hoprate":200}],"wlan1mon"),(200,0))
    def test_status_files_are_written_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            stats=str(pathlib.Path(directory)/"stats.json"); status=str(pathlib.Path(directory)/"status")
            node.write_status(stats,status,{"core":None,"seen":1})
            self.assertEqual(json.loads(pathlib.Path(stats).read_text())["seen"],1)
            self.assertIn("CORE: SEARCH",pathlib.Path(status).read_text())
            self.assertEqual(list(pathlib.Path(directory).glob("*.tmp.*")),[])
    def test_6ghz_beacon_record(self):
        present=(1<<1)|(1<<3)|(1<<5)
        rt=struct.pack("<BBHIBxHHb",0,0,15,present,0,5975,0,-42)
        mac=bytes.fromhex("aabbccddeeff")
        hdr=struct.pack("<HH6s6s6sH",0x80,0,b"\xff"*6,mac,mac,0)
        fixed=b"\0"*8+struct.pack("<HH",100,0x401)
        ies=b"\x00\x04Test"
        self.assertEqual(node.beacon_record(rt+hdr+fixed+ies),(mac,5,-42,"[OPEN]",b"Test"))
    def test_non_6ghz_frame_is_rejected(self):
        present=(1<<1)|(1<<3)|(1<<5)
        rt=struct.pack("<BBHIBxHHb",0,0,15,present,0,2412,0,-42)
        self.assertIsNone(node.beacon_record(rt+b"\0"*64))
    def test_transient_network_down_does_not_escape_receive(self):
        radio=node.Radio.__new__(node.Radio)
        radio.sock=mock.Mock()
        radio.sock.recv.side_effect=OSError(127,"Network is down")
        with mock.patch.object(node.select,"select",return_value=([radio.sock],[],[])), mock.patch.object(node.time,"sleep"):
            self.assertEqual(list(radio.receive(.01)),[])
    def test_transient_network_down_does_not_escape_send(self):
        radio=node.Radio.__new__(node.Radio); radio.mac=b"\x01"*6; radio.seq=0; radio.rt=b""; radio.sock=mock.Mock()
        radio.sock.send.side_effect=OSError(127,"Network is down")
        with mock.patch.object(node.time,"sleep"):
            self.assertFalse(radio.send(b"\x02"*6,b"test"))

if __name__=="__main__": unittest.main()
