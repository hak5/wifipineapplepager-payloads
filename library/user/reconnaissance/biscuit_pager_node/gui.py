"""Biscuit's physical-button dashboard. Uses the upstream pagerctl wrapper."""
import argparse
import json
import os
import signal
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
for path in (os.path.join(ROOT, "lib"),
             "/mmc/root/payloads/user/utilities/PAGERCTL",
             "/mmc/root/payloads/user/utilities/PAGERCTL/lib",
             "/root/payloads/user/utilities/PAGERCTL",
             "/root/payloads/user/utilities/PAGERCTL/lib"):
    sys.path.append(path)

def preflight():
    import ctypes
    from pagerctl import Pager
    # Import loads the shared library without taking over the display.
    return Pager

def state(st):
    if st.get("final"):
        return "STOPPED"
    if st.get("status") == "secure" and not st.get("biscuit"):
        return "SECURE MODE"
    if not st.get("biscuit"):
        return "SEARCHING"
    if st.get("ack_age_s") is None or st["ack_age_s"] > 10:
        return "LINK UNVERIFIED"
    if not st.get("ap6"):
        return "FW TOO OLD"
    return "SCANNING" if st.get("role") == 1 else "WAITING FOR DRIVE"

def run(args):
    Pager = preflight()
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    details = False
    with Pager() as p:
        p.set_rotation(270)
        bg, white = p.rgb(12,17,23), p.rgb(235,241,247)
        muted, green = p.rgb(152,168,184), p.rgb(116,227,192)
        amber, panel = p.rgb(246,201,117), p.rgb(20,31,41)
        logo = p.load_image(os.path.join(ROOT, "logo.png"))
        try:
            p.draw_image_file_scaled(0,0,480,222,os.path.join(ROOT,"splash.png"))
            p.flip()
            until = time.monotonic() + 1.5
            while running and time.monotonic() < until:
                _, pressed, _ = p.poll_input()
                if pressed & (Pager.BTN_B | Pager.BTN_POWER):
                    return
                time.sleep(.05)
            p.clear_input_events()
            st = {}
            while running:
                try:
                    with open(args.stats) as f:
                        st = json.load(f)
                    age = time.time() - os.path.getmtime(args.stats)
                except (OSError, ValueError):
                    age = 999
                status = state(st) if age < 8 else "STARTING" if not st else "STATS STALE"
                if not os.path.exists('/proc/%s' % args.node_pid):
                    status = "STOPPED" if st.get("final") else "NODE ERROR"
                color = green if status == "SCANNING" else amber
                p.clear(bg)
                p.draw_image_scaled(12,8,28,28,logo)
                def text(x,y,s,c=white,scale=1):
                    p.draw_text(x,y,str(s),c,scale)
                text(49,8,'BISCUIT',white,2)
                text(49,29,'PAGER NODE / 6 GHz',muted)
                text(290,17,status,color)
                p.fill_rect(12,45,456,1,p.rgb(41,51,63))
                text(14,54,'MANAGER ' + (st.get('biscuit') or '--').upper())
                ack = st.get('ack_age_s')
                if details:
                    lines = [
                        'Radio ACK age: ' + ('--' if ack is None else str(ack)+'s'),
                        'ACKs: %s   TX errors: %s' % (st.get('acks',0),st.get('tx_errors',0)),
                        'Updates TX: %s   Frames: %s' % (st.get('sent',0),st.get('frames',0)),
                        'Held for firmware: %s' % st.get('held_6ghz',0),
                        'Tune average: %s ms' % st.get('switch_ms','--'),
                        'Sent = submitted, not confirmed saved.'
                    ]
                    for i,line in enumerate(lines):
                        text(14,80+i*18,line,muted)
                else:
                    for x,label,value,c in ((14,'NETWORKS SEEN',st.get('seen',0),white),
                                             (246,'NETWORKS SENT',st.get('sent_unique',0),green)):
                        p.fill_rect(x,78,220,68,panel)
                        text(x+10,86,label,muted)
                        text(x+10,104,min(value,999999),c,3)
                    sec = st.get('uptime_s',0)
                    text(14,157,'CH %s  SWEEPS %s  QUEUED %s  %02d:%02d:%02d' %
                         (st.get('channel') or 'HOME',st.get('sweeps',0),st.get('queued_networks',0),sec//3600,sec//60%60,sec%60),muted)
                    hint = ('%s updates TX / repeat sightings included' % st.get('sent',0))
                    if status == 'SEARCHING': hint = 'Waiting for an Extended-mode manager'
                    if status == 'SECURE MODE': hint = 'Switch manager node mode to Extended'
                    if status == 'FW TOO OLD': hint = 'Update manager firmware for 6 GHz'
                    if status == 'LINK UNVERIFIED': hint = 'Manager known; waiting for radio ACK'
                    if status == 'WAITING FOR DRIVE': hint = 'Start a wardrive on the manager'
                    if status == 'NODE ERROR': hint = 'See /tmp/biscuit_node_gui.log'
                    text(14,178,hint,muted)
                p.fill_rect(12,199,456,1,p.rgb(41,51,63))
                text(14,207,'A  '+('DASHBOARD' if details else 'DETAILS'),muted)
                text(340,207,'B  STOP & EXIT',muted)
                p.flip()
                until = time.monotonic()+.2
                while running and time.monotonic()<until:
                    _, pressed, _ = p.poll_input()
                    if pressed & (Pager.BTN_B | Pager.BTN_POWER):
                        running = False
                    if pressed & Pager.BTN_A:
                        details = not details
                    time.sleep(.02)
        finally:
            p.free_image(logo)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--stats',default='/tmp/biscuit_node_gui_stats.json')
    parser.add_argument('--node-pid',type=int,default=0)
    args = parser.parse_args()
    if args.check: preflight()
    else: run(args)
