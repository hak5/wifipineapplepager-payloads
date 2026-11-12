import json, sys


def outcome(st):
    if not st.get("biscuit"):
        return "yellow|Never reached a Biscuit"
    mac = st["biscuit"].upper()
    if st["sent"] == 0 and st.get("role") != 1:
        return f"yellow|Joined {mac}, no drive started"
    return f"green|Fed Biscuit {mac}"


def counts_line(st):
    line = f"6 GHz seen {st['seen']:>4}  sent {st['sent']:>4}"
    if st.get("held_6ghz") and not st.get("ap6"):
        line += f"  held {st['held_6ghz']}"
    return f"white|{line}"


def duration(s):
    h, m = divmod(s // 60, 60)
    return f"{h}h {m:02d}m" if h else f"{m}m {s % 60:02d}s"


def main():
    mode, path = sys.argv[1], sys.argv[2]
    st = json.load(open(path))
    if mode == "summary":
        lines = ["cyan|Stopped after " + duration(st["uptime_s"]), outcome(st), counts_line(st)]
        if st.get("held_6ghz") and not st.get("ap6"):
            lines.append("yellow|6 GHz held: Biscuit firmware too old")
        print("\n".join(lines))
    elif mode == "prompt":
        msg = f"Sent {st['sent']} network updates to the Biscuit"
        if st.get("held_6ghz") and not st.get("ap6"):
            msg += f". {st['held_6ghz']} 6 GHz networks held"
        print(msg)


if __name__ == "__main__":
    main()
