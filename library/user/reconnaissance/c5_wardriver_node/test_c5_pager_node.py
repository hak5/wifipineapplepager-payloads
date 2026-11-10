import importlib.util, pathlib, struct, unittest
from unittest import mock

PATH=pathlib.Path(__file__).with_name("c5_pager_node.py")
spec=importlib.util.spec_from_file_location("node",PATH); node=importlib.util.module_from_spec(spec); spec.loader.exec_module(node)

class PayloadTests(unittest.TestCase):
    def test_payload_exposes_mmc_python_packages(self):
        payload=PATH.with_name("payload.sh").read_text()
        self.assertIn("PYTHON_MMCLIB",payload)
        self.assertLess(payload.index("export PYTHONPATH"), payload.index('python3 "$DIR/c5_pager_node.py"'))
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
    def test_splash_is_pager_sized_title_card(self):
        data=PATH.with_name("splash.png").read_bytes()
        self.assertEqual(data[:8],b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II",data[16:24]),(480,222))

class ProtocolTests(unittest.TestCase):
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
        self.assertIn("src==wanted",source)
        self.assertIn('IW_BIN=os.environ.get("IW_BIN","/usr/sbin/iw")',source)
        self.assertIn("subprocess.run([IW_BIN",source)
        self.assertIn("text_message(CORE_REQUEST,text=CAPABILITIES)",source)
        self.assertIn("text_message(HEARTBEAT,heartbeat,CAPABILITIES)",source)
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
