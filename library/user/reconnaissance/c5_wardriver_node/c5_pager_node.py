#!/usr/bin/env python3
"""Clean-room C5 Wardriver scan-only node for the WiFi Pineapple Pager."""
import argparse, json, os, select, socket, struct, subprocess, time

MAGIC=b"ENOW"; OUI=bytes.fromhex("18fe34"); BROADCAST=b"\xff"*6
IW_BIN=os.environ.get("IW_BIN","/usr/sbin/iw")
CORE_REQUEST=1; CORE_REPLY=2; HEARTBEAT=3; TEXT=4; RECORD_ACK=6
CAPABILITIES=b"C5P1;ROLE=EXTERNAL;BANDS=6"
HOME_FREQ=2437; PSC=[5,21,37,53,69,85,101,117,133,149,165,181,197,213,229]

def text_message(kind,counter=0,text=b""):
    text=text[:200]
    return struct.pack("<4sBIH",MAGIC,kind,counter,len(text))+text.ljust(201,b"\0")

def parse_text_message(payload):
    if len(payload)!=212 or payload[:4]!=MAGIC: return None
    kind=payload[4]; counter,n=struct.unpack_from("<IH",payload,5)
    if n>200: return None
    return kind,counter,payload[11:11+n]

def radiotap(pkt):
    if len(pkt)<8: return None
    length=struct.unpack_from("<H",pkt,2)[0]
    if length<8 or length>len(pkt): return None
    off=4; words=[]
    while True:
        if off+4>length: return None
        word=struct.unpack_from("<I",pkt,off)[0]; words.append(word); off+=4
        if not word&0x80000000: break
    fields={0:(8,8),1:(1,1),2:(1,1),3:(2,4),4:(2,2),5:(1,1),6:(1,1),7:(2,2),8:(2,2),9:(2,2),10:(1,1),11:(1,1),12:(1,1),13:(1,1),14:(2,2),15:(2,2),16:(1,1),17:(1,1)}
    values={}
    for bit in range(18):
        if not words[0]&(1<<bit): continue
        align,size=fields[bit]; off=(off+align-1)&~(align-1)
        if off+size>length: return None
        values[bit]=pkt[off:off+size]; off+=size
    flags=values.get(1,b"\0")[0]
    mhz=struct.unpack_from("<H",values[3],0)[0] if 3 in values else 0
    signal=struct.unpack("<b",values[5])[0] if 5 in values else None
    return length,flags,mhz,signal

def security(frame):
    privacy=bool(frame[34]&0x10); rsn=None; wpa=False; p=36
    while p+2<=len(frame):
        eid,n=frame[p],frame[p+1]; p+=2
        if p+n>len(frame): return "[UNDEFINED]"
        body=frame[p:p+n]; p+=n
        if eid==48: rsn=body
        elif eid==221 and body[:4]==b"\x00\x50\xf2\x01": wpa=True
    if rsn is not None:
        if b"\x00\x0f\xac\x12" in rsn: return "[OWE]"
        if b"\x00\x0f\xac\x08" in rsn: return "[WPA3_PSK]"
        if b"\x00\x0f\xac\x02" in rsn: return "[WPA2_PSK]"
        return "[WPA2_ENTERPRISE]"
    if wpa: return "[WPA_PSK]"
    return "[WEP]" if privacy else "[OPEN]"

def beacon_record(pkt):
    info=radiotap(pkt)
    if not info: return None
    rlen,flags,mhz,rssi=info; frame=pkt[rlen:-4] if flags&0x10 else pkt[rlen:]
    if len(frame)<36 or frame[0] not in (0x80,0x50) or rssi is None or not 5925<=mhz<=7125: return None
    channel=(mhz-5950)//5
    if channel<1 or channel>233 or (channel-1)%4: return None
    ssid=None; p=36
    while p+2<=len(frame):
        eid,n=frame[p],frame[p+1]; p+=2
        if p+n>len(frame): return None
        if eid==0: ssid=frame[p:p+min(n,32)]
        p+=n
    if ssid is None: return None
    return frame[16:22],channel,rssi,security(frame),ssid.replace(b",",b"_").replace(b"\n",b"_").replace(b"\r",b"_")

class Radio:
    def __init__(self,iface):
        self.iface=iface; self.mac=bytes.fromhex(open(f"/sys/class/net/{iface}/address").read().strip().replace(":","")); self.seq=0
        self.sock=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(3)); self.sock.bind((iface,0))
        self.rt=struct.pack("<BBHIBxH",0,0,12,(1<<2)|(1<<15),2,0)
    def send(self,dst,payload):
        self.seq=(self.seq+1)&0xfff
        hdr=struct.pack("<HH6s6s6sH",0x00d0,0,dst,self.mac,BROADCAST,self.seq<<4)
        body=b"\x7f"+OUI+os.urandom(4)+b"\xdd"+bytes([len(payload)+5])+OUI+b"\x04\x01"+payload
        try:
            self.sock.send(self.rt+hdr+body)
            return True
        except OSError:
            # Channel/service transitions can briefly report ENETDOWN.
            time.sleep(.1)
            return False
    def receive(self,seconds,beacons=False):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            ready,_,_=select.select([self.sock],[],[],min(.05,end-time.monotonic()))
            if not ready: continue
            try:
                pkt=self.sock.recv(4096)
            except OSError:
                # Keep the long-running payload alive across transient radio resets.
                time.sleep(.1)
                return
            info=radiotap(pkt)
            if not info: continue
            frame=pkt[info[0]:]
            if beacons and len(frame)>=36 and frame[0] in (0x80,0x50): yield "beacon",pkt; continue
            if len(frame)<39 or (frame[0]&0xfc)!=0xd0: continue
            dst,src=frame[4:10],frame[10:16]
            if src==self.mac or dst not in (self.mac,BROADCAST): continue
            body=frame[24:]
            if len(body)<15 or body[0]!=0x7f or body[1:4]!=OUI or body[8]!=0xdd or body[10:13]!=OUI: continue
            yield "message",(src,body[15:10+body[9]])

def tune(iface,mhz):
    return subprocess.run([IW_BIN,"dev",iface,"set","freq",str(mhz)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0

def discover_cores(radio,iface,seconds):
    found=set(); deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        tune(iface,HOME_FREQ)
        radio.send(BROADCAST,text_message(CORE_REQUEST,text=CAPABILITIES))
        for kind,item in radio.receive(.45):
            if kind!="message": continue
            src,payload=item; parsed=parse_text_message(payload)
            if parsed and parsed[0]==CORE_REPLY: found.add(src)
    return sorted(found)

def format_status(stats):
    latest=stats.get("latest") or {}
    ssid=str(latest.get("ssid") or "--").replace("\n","_").replace("\r","_")[:22]
    channel=latest.get("channel","--"); rssi=latest.get("rssi","--")
    state="LINKED" if stats.get("core") else "SEARCH"
    return "\n".join((
        f"CORE: {state}",
        f"NET: {ssid}",
        f"CH: {channel}  RSSI: {rssi} dBm",
        f"SEEN: {stats.get('seen',0)}  QUEUE: {stats.get('queued',0)}",
        f"TX: {stats.get('sent',0)}  ACK: {stats.get('acked',0)}  DROP: {stats.get('dropped',0)}",
        "A: STOP",
    ))

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--iface",default="wlan1mon"); ap.add_argument("--core"); ap.add_argument("--stats",default="/tmp/c5-pager-node.json"); ap.add_argument("--render-stats"); ap.add_argument("--discover-seconds",type=float); a=ap.parse_args()
    if a.render_stats:
        try:
            with open(a.render_stats) as f: print(format_status(json.load(f)))
        except (OSError,ValueError): print(format_status({}))
        return
    radio=Radio(a.iface)
    if a.discover_seconds is not None:
        for mac in discover_cores(radio,a.iface,max(.5,a.discover_seconds)): print(mac.hex(":"))
        return
    if not a.core: ap.error("--core is required")
    wanted=bytes.fromhex(a.core.replace(":","")); core=None; heartbeat=0; record_counter=struct.unpack("<I",os.urandom(4))[0]; seen={}; queue=[]; attempts={}; sent=0; acked=0; dropped=0; last_ack=None; latest=None; sweeps=0
    while True:
        tune(a.iface,HOME_FREQ)
        if core is None:
            radio.send(BROADCAST,text_message(CORE_REQUEST,text=CAPABILITIES))
            for kind,item in radio.receive(.35):
                if kind=="message":
                    src,payload=item; parsed=parse_text_message(payload)
                    if parsed and parsed[0]==CORE_REPLY and src==wanted: core=src
        else:
            radio.send(core,text_message(HEARTBEAT,heartbeat,CAPABILITIES)); heartbeat+=1
            drain_deadline=time.monotonic()+.5
            while queue and time.monotonic()<drain_deadline:
                rec=queue.pop(0); bssid,ch,rssi,auth,ssid=rec
                line=bssid.hex(":").upper().encode()+b","+ssid+b","+auth.encode()+f",{ch},{rssi},W6".encode()
                expected_ack=f"W6,{5950+5*ch}".encode()
                record_counter=(record_counter+1)&0xffffffff
                radio.send(core,text_message(TEXT,record_counter,line)); sent+=1
                acknowledged=False
                for kind,item in radio.receive(.15):
                    if kind != "message": continue
                    src,payload=item; parsed=parse_text_message(payload)
                    if src==core and parsed and parsed[0]==RECORD_ACK and parsed[1]==record_counter and parsed[2]==expected_ack:
                        acked+=1; last_ack=parsed[2].decode("ascii"); acknowledged=True; break
                if acknowledged:
                    attempts.pop(bssid,None)
                else:
                    count=attempts.get(bssid,0)+1
                    if count<3: attempts[bssid]=count; queue.append(rec)
                    else: attempts.pop(bssid,None); dropped+=1
            radio.receive(.15)
        for ch in PSC:
            if not tune(a.iface,5950+5*ch): continue
            for kind,item in radio.receive(.11,beacons=True):
                if kind!="beacon": continue
                rec=beacon_record(item)
                if not rec: continue
                now=time.monotonic(); bssid=rec[0]
                latest={"ssid":rec[4].decode("utf-8","replace"),"channel":rec[1],"rssi":rec[2],"bssid":bssid.hex(":")}
                if now-seen.get(bssid,-999)<30: continue
                seen[bssid]=now
                if len(queue)>=256: queue.pop(0)
                queue.append(rec)
        sweeps+=1
        tmp=a.stats+".tmp"
        with open(tmp,"w") as f: json.dump({"core":core.hex(":") if core else None,"seen":len(seen),"queued":len(queue),"sent":sent,"acked":acked,"dropped":dropped,"last_ack":last_ack,"latest":latest,"sweeps":sweeps},f)
        os.replace(tmp,a.stats)

if __name__=="__main__": main()
