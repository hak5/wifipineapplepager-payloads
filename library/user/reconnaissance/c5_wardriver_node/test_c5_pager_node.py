import importlib.util, json, pathlib, struct, tempfile, unittest
from unittest import mock

PATH=pathlib.Path(__file__).with_name("c5_pager_node.py")
spec=importlib.util.spec_from_file_location("node",PATH); node=importlib.util.module_from_spec(spec); spec.loader.exec_module(node)
GUI_PATH=PATH.with_name("gui.py")
gui_spec=importlib.util.spec_from_file_location("gui",GUI_PATH); gui=importlib.util.module_from_spec(gui_spec); gui_spec.loader.exec_module(gui)

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
        pairing=payload[payload.index('"Pair nearby Core")'):payload.index('"Enter Core MAC")')]
        self.assertIn('confirmed "Pair with $CORE_MAC?" || exit 0',pairing)
        self.assertLess(pairing.index("confirmed"),pairing.index("save_core"))
        self.assertIn('[ -n "${DUCKYSCRIPT_USER_CONFIRMED:-}" ]',payload)
        self.assertNotIn("DUCKYSCRIPT_USER_CONFIRMED:-1",payload)
    def test_payload_owns_gui_worker_and_display_cleanup(self):
        payload=PATH.with_name("payload.sh").read_text()
        for expected in ("GUI_PID", "DISPLAY_SET", "stop_pid", "UI_TAKEOVER", "UI_RELEASE", '"$DIR/gui.py" --stats'):
            self.assertIn(expected,payload)
        self.assertIn("python3-ctypes",payload)
        self.assertIn("DUCKYSCRIPT_USER_CONFIRMED",payload)
        self.assertIn("install_pagerctl.sh",payload)
        self.assertNotIn("trap cleanup EXIT INT TERM",payload)
        self.assertNotIn("/etc/init.d/pineapd restart",payload)
        self.assertNotIn("/etc/init.d/pineapplepager stop",payload)
        self.assertIn('_pineap INTERFACE SET "$IFACE" CHANNEL 6',payload)
        self.assertIn('_pineap INTERFACE SET "$IFACE" HOP fast',payload)
        self.assertIn('OLD_CHANNEL=$(iw dev "$IFACE" info',payload)
        self.assertIn('printf "%s\\n" "$$" >"$LOCK/pid"',payload)
        self.assertIn('rm -f "$LOCK/pid"',payload)
        self.assertIn('/proc/$LOCK_PID/cmdline',payload)
    def test_pagerctl_download_is_pinned_and_hashed(self):
        installer=PATH.with_name("install_pagerctl.sh").read_text()
        self.assertIn("30ef1028500ba1d0303d24ea5d62497407bac77d",installer)
        self.assertIn("57238e7720498d0de65504efcebc1a8f27f8c1b952ed3bbb718595006d951b08",installer)
        self.assertIn("f0f5d3213c77e360fa4cf912c5a122d2dd1b39713ae2cdf7c6ba6dc7ead5e4e5",installer)
        self.assertIn('VERSION_ID="${REV}-${PY_SHA}-${SO_SHA}"',installer)
        self.assertIn('ACTIVE="$LIB_ROOT/active"',installer)
        self.assertIn('mv -fT "$LINK_TMP" "$ACTIVE"',installer)

    def test_gui_preflight_rejects_corrupt_pinned_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory); versions=root/"lib"/"versions"
            version=versions/(gui.PAGERCTL_REV+"-test"); version.mkdir(parents=True)
            module=version/"pagerctl.py"; library=version/"libpagerctl.so"
            module.write_text("class Pager: pass\n"); library.write_bytes(b"valid-library")
            (root/"lib"/"active").symlink_to(pathlib.Path("versions")/version.name)
            font=root/"font.ttf"; logo=root/"logo.png"; font.write_bytes(b"font"); logo.write_bytes(b"logo")
            with mock.patch.multiple(gui,ROOT=str(root),PAGERCTL_PATH=str(root/"lib"/"active"),FONT_PATH=str(font),LOGO_PATH=str(logo),PAGERCTL_PY_SHA256=gui.sha256_file(module),PAGERCTL_SO_SHA256=gui.sha256_file(library)):
                self.assertEqual(gui.preflight().__name__,"Pager")
                library.write_bytes(b"corrupt-library")
                with self.assertRaisesRegex(ImportError,"hash verification"):
                    gui.preflight()

    def test_gui_setup_log_is_truncated_before_preflight(self):
        payload=PATH.with_name("payload.sh").read_text()
        truncate=': >"$SETUP_LOG"'
        preflight='"$DIR/gui.py" --check >>"$SETUP_LOG"'
        self.assertIn(truncate,payload)
        self.assertLess(payload.index(truncate),payload.index(preflight))

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
        self.assertIn("CORE_LINK_TIMEOUT=15.0",source)
        self.assertIn("PSC_DWELL=.20",source)
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
        for expected in ("CORE: LINKED","NET: Pager Test","CH: 5  RSSI: -42 dBm","SEEN: 12  QUEUE: 3","TX: 10  ACK: 9  DROP: 1","B: STOP"):
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
        self.assertEqual(node.interface_state([{"ifname":"wlan1mon","hop":False,"hoprate":0}],"wlan1mon"),(0,0))
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
    def test_receive_timeout_is_never_negative(self):
        self.assertEqual(node.bounded_wait(10.0,10.1),0.0)
        self.assertAlmostEqual(node.bounded_wait(10.0,9.98),.02)
    def test_transient_network_down_does_not_escape_send(self):
        radio=node.Radio.__new__(node.Radio); radio.mac=b"\x01"*6; radio.seq=0; radio.rt=b""; radio.sock=mock.Mock()
        radio.sock.send.side_effect=OSError(127,"Network is down")
        with mock.patch.object(node.time,"sleep"):
            self.assertFalse(radio.send(b"\x02"*6,b"test"))
    def test_pager_dedup_suppresses_recent_and_queued_bssids(self):
        bssid=bytes.fromhex("aabbccddeeff"); recent={}; queued=set()
        self.assertTrue(node.accept_record(bssid,100,recent,queued))
        self.assertFalse(node.accept_record(bssid,110,recent,queued))
        self.assertTrue(node.accept_record(bssid,131,recent,queued))
        queued.add(bssid)
        self.assertFalse(node.accept_record(bssid,200,recent,queued))
    def test_dedupe_cache_prunes_by_age_and_limit(self):
        recent={bytes([i]):float(i) for i in range(10)}
        node.prune_recent(recent,now=10,window=20,limit=4)
        self.assertEqual(list(sorted(recent.values())),[6.0,7.0,8.0,9.0])
        node.prune_recent(recent,now=30,window=10,limit=4)
        self.assertEqual(recent,{})
    def test_only_matching_record_ack_marks_link_health(self):
        source=PATH.read_text()
        self.assertEqual(source.count("last_ack_at=time.monotonic()"),1)
        ack_clause='parsed[0]==RECORD_ACK and parsed[1]==record_counter and parsed[2]==expected_ack'
        self.assertIn(ack_clause,source)
        self.assertNotIn("last_core_rx",source)

class FakePager:
    def __init__(self): self.calls=[]
    def rgb(self,*rgb): return rgb
    def _call(self,name,*args): self.calls.append((name,args))
    def clear(self,*args): self._call("clear",*args)
    def line(self,*args): self._call("line",*args)
    def fill_rect(self,*args): self._call("fill_rect",*args)
    def draw_text(self,*args): self._call("draw_text",*args)
    def draw_ttf(self,x,y,text,color,font_path,font_size): self._call("draw_text",x,y,text,color,font_size); return self.ttf_width(text,font_path,font_size)
    def ttf_width(self,text,font_path,font_size): return int(len(str(text))*font_size*.55)
    def draw_image_file(self,*args): self._call("draw_image_file",*args)
    def draw_image(self,*args): self._call("draw_image",*args)

class GuiTests(unittest.TestCase):
    def sample(self):
        return {"core":"3c:dc:75:86:de:94","paired_core":"3c:dc:75:86:de:94","ack_age_s":2,
                "devices":55,"sent":42,"acked":40,"queued":3,"dropped":1,"deduped":80,
                "sweeps":9,"uptime_s":125,"channel_activity":[0,1,3,8,2,0,4,12,1,0,5,2,1,0,3],
                "latest":{"ssid":"JCMK Lab","channel":117,"rssi":-41,"bssid":"aa:bb:cc:dd:ee:ff"}}
    def test_dashboard_has_jcmk_brand_required_metrics_and_all_psc_bars(self):
        pager=FakePager(); gui.draw_dashboard(pager,self.sample(),age=1,node_alive=True,details=False)
        texts=[args[2] for name,args in pager.calls if name=="draw_text"]
        for expected in ("JCMK  /  C5 NODE","CORE LINKED","DEVICES","CHANNEL ACTIVITY","6 GHz PSC"):
            self.assertIn(expected,texts)
        bars=[args for name,args in pager.calls if name=="fill_rect" and len(args)>=4 and args[2]==12]
        self.assertGreaterEqual(len(bars),len(gui.PSC))
    def test_details_page_includes_pair_and_transport_health(self):
        pager=FakePager(); gui.draw_dashboard(pager,self.sample(),age=1,node_alive=True,details=True)
        texts=[str(args[2]) for name,args in pager.calls if name=="draw_text"]
        for expected in ("SENT","ACKED","QUEUE","DROP","LATEST NETWORK","JCMK Lab"):
            self.assertIn(expected,texts)
        for expected in ("OVERVIEW","TELEMETRY","B  EXIT"):
            self.assertIn(expected,texts)
    def test_status_distinguishes_stale_process_and_link(self):
        st=self.sample()
        self.assertEqual(gui.dashboard_status(st,1,True),("CORE LINKED","ok"))
        self.assertEqual(gui.dashboard_status(st,9,True),("STATS STALE","warn"))
        self.assertEqual(gui.dashboard_status(st,1,False),("NODE ERROR","error"))
    def test_gui_uses_only_exact_payload_local_pagerctl(self):
        source=GUI_PATH.read_text()
        self.assertIn('PAGERCTL_PATH = os.path.join(ROOT, "lib", "active")',source)
        self.assertIn('spec_from_file_location("jcmk_pagerctl", module_path)',source)
        self.assertNotIn("from pagerctl import",source)
        self.assertNotIn('/root/payloads/user/utilities/PAGERCTL',source)
        self.assertNotIn('/mmc/root/payloads/user/utilities/PAGERCTL',source)
        self.assertIn('FONT_PATH = os.path.join(ROOT, "fonts", "Lato-Medium.ttf")',source)
        self.assertIn("draw_ttf",source)
        self.assertIn('LOGO_PATH = os.path.join(ROOT, "jcmk_mark.png")',source)
        self.assertIn("load_image(LOGO_PATH)",source)
    def test_gui_surfaces_device_cap_and_worker_failure(self):
        pager=FakePager(); sample=self.sample(); sample["devices_capped"]=True
        gui.draw_dashboard(pager,sample,age=1,node_alive=True,details=False)
        texts=[str(args[2]) for name,args in pager.calls if name=="draw_text"]
        self.assertIn("55+",texts)
        self.assertIn("return 2",GUI_PATH.read_text())
        self.assertIn("return 0 if result is None else result",GUI_PATH.read_text())
        source=GUI_PATH.read_text()
        self.assertIn("Pager.BTN_RIGHT",source)
        self.assertIn("Pager.BTN_LEFT",source)
        self.assertIn("Pager.BTN_B",source)
        self.assertNotIn("Pager.BTN_POWER",source)
        self.assertNotIn("Pager.BTN_B | Pager.BTN_POWER",source)
    def test_zombie_worker_is_not_alive(self):
        with mock.patch("builtins.open",mock.mock_open(read_data="12 (worker) Z 1 2 3")):
            self.assertFalse(gui.process_alive(12))
        with mock.patch("builtins.open",mock.mock_open(read_data="12 (worker) S 1 2 3")):
            self.assertTrue(gui.process_alive(12))

if __name__=="__main__": unittest.main()
