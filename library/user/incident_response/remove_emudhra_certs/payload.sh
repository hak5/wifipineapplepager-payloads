#!/bin/bash
# Title: Remove compromised eMudhra CA roots
# Description: Notifies the user of the October 2026 eMudhra intermediate CA key compromise and, after confirmation, removes the affected CA roots from /etc/ssl
# Author: dragorn
# Version: 1.1
#
# The removal script is embedded at the end of this payload.  It matches
# certificates by content and backs up every file it changes to
# /root/emudhra-certs-backup-*.tar.

# Send multi-line script output to the payload log
log_lines() {
    local color="$1" line
    while IFS= read -r line; do
        [ -n "$line" ] && LOG "$color" "$line"
    done <<< "$2"
}

main() {
    REMOVER=/tmp/remove-emudhra-certs.$$.sh
    trap 'rm -f "$REMOVER"' EXIT
    write_remover "$REMOVER" || {
        ERROR_DIALOG "Could not write the removal script to /tmp"
        exit 1
    }

    LOG "Scanning /etc/ssl for eMudhra-linked CA roots..."
    plan=$(sh "$REMOVER" --check --quiet 2>&1)
    case $? in
        0)
            LOG green "No affected certificates found"
            PROMPT "No compromised eMudhra CA certificates found on this Pager. Nothing to do."
            exit 0
            ;;
        2)
            ;;
        *)
            log_lines red "$plan"
            ERROR_DIALOG "Certificate scan failed; see payload log"
            exit 1
            ;;
    esac

    log_lines yellow "$plan"

    # Notification and explanation of the flaw
    PROMPT "SECURITY NOTICE: This Pager trusts CA roots linked to the compromised eMudhra intermediate CAs."
    PROMPT "eMudhra generated 8 intermediate CA keys with weak randomness. Anyone can recover the private keys from the public certificates."
    PROMPT "With those keys an attacker can forge a valid TLS certificate for ANY site and intercept HTTPS traffic from this device."
    PROMPT "Browsers block these CAs, but tools on the Pager (opkg/apk, wget, curl) do not check revocation or certificate transparency."
    PROMPT "The fix removes the emSign ECC Root CA - G3 and Comodo AAA Certificate Services roots. Files are backed up to /root first."

    resp=$(CONFIRMATION_DIALOG "Remove the affected CA certificates now?")
    case $? in
        $DUCKYSCRIPT_REJECTED)
            LOG "Dialog rejected"
            exit 0
            ;;
        $DUCKYSCRIPT_ERROR)
            ERROR_DIALOG "Confirmation dialog failed"
            exit 1
            ;;
    esac

    if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG yellow "Cancelled by user; no changes made"
        PROMPT "Cancelled. No certificates were changed."
        exit 0
    fi

    LOG "Removing certificates..."
    # Single-word message for compatibility with firmware 1.0.4 and older
    spinner=$(START_SPINNER "Removing")
    out=$(sh "$REMOVER" --yes --quiet 2>&1)
    rc=$?
    STOP_SPINNER "$spinner"

    if [ "$rc" -ne 0 ]; then
        log_lines red "$out"
        ERROR_DIALOG "Certificate removal failed; see payload log"
        exit 1
    fi

    log_lines green "$out"
    PROMPT "Done. Compromised eMudhra CA roots removed. A backup is in /root/emudhra-certs-backup-*.tar."

    exit 0
}

write_remover() {
    (set -C; cat > "$1") <<'REMOVE_EMUDHRA_CERTS_EOF'
#!/bin/sh
#
# remove-emudhra-certs.sh
#
# Remove the CA roots implicated in the October 2026 eMudhra intermediate CA
# key compromise (emSign ECC Root CA - G3 and Comodo AAA Certificate Services)
# from an OpenWrt or Debian trust store, /etc/ssl by default.
#
# Certificates are identified by content, not filename.  Single-certificate
# files are removed along with the hash symlinks pointing at them, and
# bundles such as ca-certificates.crt are rewritten without the roots.  On
# Debian-style systems the roots are also deselected in
# /etc/ca-certificates.conf and update-ca-certificates is run, so later
# ca-certificates updates keep them out.  Everything changed is first saved
# to a tar archive; restore it with "tar -xf ARCHIVE -C /" (followed by
# update-ca-certificates on Debian).
#
# Requires only BusyBox (sh, awk, find, grep, readlink, tar).
#
# Exit codes:
#   0  nothing to do, or certificates were removed successfully
#   1  error
#   2  (--check only) affected certificates are present
#   3  user declined
#

SSL_DIR=/etc/ssl
BACKUP_PARENT=/root
ASSUME_YES=0
CHECK_ONLY=0
QUIET=0

usage() {
	cat <<EOF
Usage: $0 [options]

Remove CA roots that trust the compromised eMudhra intermediate CAs.

  -y, --yes             do not ask for confirmation
  -n, --check           only report affected files; exit 2 if any are found
  -q, --quiet           do not print the explanation of the compromise
  -d, --dir DIR         trust store directory to scan (default: /etc/ssl)
  -b, --backup-dir DIR  where to write the backup archive (default: /root)
  -h, --help            show this help
EOF
}

die() {
	echo "error: $*" >&2
	exit 1
}

explain() {
	cat <<'EOF'
================================================================================
 eMudhra intermediate CA key compromise (disclosed October 2026)
================================================================================

What happened
  In April 2025 the eMudhra certificate authority created eight intermediate
  CA certificates (EM DV/OV/EV TLS CA - G3B and G3C, EM OV CS CA - G3B and
  G3C).  Their private keys were generated with insufficient randomness, so
  anyone can recompute each private key from the public certificate alone,
  in under a second.

Why it matters
  Anyone holding one of these keys can mint a certificate for ANY hostname
  that every client trusting the roots above them will accept, allowing
  silent man-in-the-middle of HTTPS and other TLS connections.

Who is still exposed
  Browsers enforce Certificate Transparency and pushed emergency blocks
  (Firefox and Chrome 2026-10-17, Apple 2026-10-19, Microsoft 2026-10-20).
  Tools on OpenWrt and Debian based devices, such as uclient-fetch, wget,
  curl, opkg and apt, check neither CT nor revocation, and will trust forged
  certificates until the roots that signed the intermediates are removed.

What this script removes
  emSign ECC Root CA - G3    (eMudhra)
  AAA Certificate Services   (Sectigo/Comodo; cross-signed all eight)
  These are the roots named in the distrust workarounds published at
  https://emudhra.we-have-a-problem.com/

Side effects
  Sites whose certificates chain only to these roots will fail verification.
  Current Sectigo certificates also validate through the USERTrust roots,
  which stay trusted.

EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	-y|--yes) ASSUME_YES=1 ;;
	-n|--check) CHECK_ONLY=1 ;;
	-q|--quiet) QUIET=1 ;;
	-d|--dir)
		[ $# -ge 2 ] || die "$1 requires an argument"
		shift
		SSL_DIR="$1"
		;;
	-b|--backup-dir)
		[ $# -ge 2 ] || die "$1 requires an argument"
		shift
		BACKUP_PARENT="$1"
		;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

[ -d "$SSL_DIR" ] || die "$SSL_DIR is not a directory"
# Resolve symlinks so symlink targets can be compared against found files
SSL_DIR=$(cd "$SSL_DIR" && pwd -P) || die "cannot resolve $SSL_DIR"

if [ "$CHECK_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
	die "must be run as root (use --check to scan without root)"
fi

WORK=$(mktemp -d 2>/dev/null) || {
	# Not every embedded image ships mktemp; /tmp is root-only on these devices
	WORK=/tmp/emudhra-certs.$$
	mkdir -m 700 "$WORK" || die "cannot create $WORK"
}
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM HUP

# Blocklist: label|PEM base64 body with all whitespace removed.  The base64
# of a DER certificate is canonical, so comparing normalized bodies is
# equivalent to comparing fingerprints without needing an openssl binary,
# which most OpenWrt images lack.
# Source: https://emudhra.we-have-a-problem.com/roots.json
cat > "$WORK/blocklist" <<'EOF'
# SHA-256 86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B
emSign ECC Root CA - G3|MIICTjCCAdOgAwIBAgIKPPYHqWhwDtqLhDAKBggqhkjOPQQDAzBrMQswCQYDVQQGEwJJTjETMBEGA1UECxMKZW1TaWduIFBLSTElMCMGA1UEChMcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0gRzMwHhcNMTgwMjE4MTgzMDAwWhcNNDMwMjE4MTgzMDAwWjBrMQswCQYDVQQGEwJJTjETMBEGA1UECxMKZW1TaWduIFBLSTElMCMGA1UEChMcZU11ZGhyYSBUZWNobm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0gRzMwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAQjpQy4LRL1KPOxst3iAhKAnjlfSU2fySU0WXTsuwYc58Byr+iuL+FBVIcUqEqy6HyC5ltqtdyzdc6LBtCGI79G1Y4PPwT01xySfvalY8L1X44uT6EYGQIrMgqCZH0Wk9GjQjBAMB0GA1UdDgQWBBR8XQKEE9TMipuBzhccLikenEhjQjAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAwNpADBmAjEAvvNhzwIQHWSVB7gYboiFBS+DCBeQyh+KTOgNG3qxrdWBCUfvO6wIBHxcmbHtRwfSAjEAnbpV/KlK6O3t5nYBQnvI+GDZjVGLVTv7jHvrZQnD+JbNR6iC8hZVdyR+EhCVBCyj
# SHA-256 D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4
AAA Certificate Services|MIIEMjCCAxqgAwIBAgIBATANBgkqhkiG9w0BAQUFADB7MQswCQYDVQQGEwJHQjEbMBkGA1UECAwSR3JlYXRlciBNYW5jaGVzdGVyMRAwDgYDVQQHDAdTYWxmb3JkMRowGAYDVQQKDBFDb21vZG8gQ0EgTGltaXRlZDEhMB8GA1UEAwwYQUFBIENlcnRpZmljYXRlIFNlcnZpY2VzMB4XDTA0MDEwMTAwMDAwMFoXDTI4MTIzMTIzNTk1OVowezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4GA1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAfBgNVBAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAL5AnfRu4ep2hxxNRUSOvkbIgwadwSr+GB+O5AL686tdUIoWMQuaBtDFcCLNSS1UY8y2bmhGC1Pqy0wkwLxyTurxFa70VJoSCsN6sjNg4tqJVfMiWPPe3M/vg4aijJRPn2jymJBGhCfHdr/jzDUsi14HZGWCwEiwqJH5YZ92IFCokcdmtet4YgNW8IoaE+oxox6gmf049vYnMlhvB/VruPsUK6+3qszWY19zjNoFmag4qMsXeDZRrOme9Hg6jc8P2ULimAyrL58OAd7vn5lJ8S3frHRNG5i1R8XlKdH5kBjHYpy+g8cmez6KJcfA3Z3mNWgQIJ2P2N7Sw4ScDV7oL8kCAwEAAaOBwDCBvTAdBgNVHQ4EFgQUoBEKIz6W8Qfs4q8p74Klf9AwpLQwDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wewYDVR0fBHQwcjA4oDagNIYyaHR0cDovL2NybC5jb21vZG9jYS5jb20vQUFBQ2VydGlmaWNhdGVTZXJ2aWNlcy5jcmwwNqA0oDKGMGh0dHA6Ly9jcmwuY29tb2RvLm5ldC9BQUFDZXJ0aWZpY2F0ZVNlcnZpY2VzLmNybDANBgkqhkiG9w0BAQUFAAOCAQEACFb8AvCb6P+k+tZ7xkSAzk/ExfYAWMymtrwUSWgEdujm7l3sAg9g1o1QGE8mTgHj5rCl7r+8dFRBv/38ErjHT1r0iWAFf2C3BUrz9vHCv8S5dIa2LX1rzNLzRt0vxuBqw8M0Ayx9lt1awg6nCpnBBYurDC/zXDrPbDdVCYfeU0BsWO/8tqtlbgT2G9w84FoVxp7Z8VlIMCFlA2zs6SFz7JsDoeA3raAVGI/6ugLOpyypEBMs1OUIJqsil2D4kF501KKaU73yqWjgom7C12yxow+ev+to51byrvLjKzg6CYG1a4XXvi3tPxq3smPi9WIsgtRqAEFQ8TmDn5XpNpaYbg==
EOF

# Scan one PEM file and print "total hits labels".  When $out is set, every
# certificate not on the blocklist (and every non-certificate line) is
# copied to $out.
FILTER_AWK='
BEGIN {
	while ((getline line < blocklist) > 0)
		if (line !~ /^#/ && (i = index(line, "|")))
			bad[substr(line, i + 1)] = substr(line, 1, i - 1)
	close(blocklist)
}
/-----BEGIN CERTIFICATE-----/ {
	incert = 1
	buf = ""
	body = ""
}
incert {
	buf = buf $0 "\n"
	if ($0 !~ /-----/) {
		l = $0
		gsub(/[ \t\r]/, "", l)
		body = body l
	}
	if ($0 ~ /-----END CERTIFICATE-----/) {
		incert = 0
		total++
		if (body in bad) {
			hits++
			if (!(body in seen)) {
				seen[body] = 1
				labels = labels (labels == "" ? "" : "; ") bad[body]
			}
		} else if (out != "") {
			printf "%s", buf > out
		}
	}
	next
}
out != "" { print > out }
END {
	# Never silently drop a truncated trailing block
	if (incert && out != "")
		printf "%s", buf > out
	print total + 0, hits + 0, labels
}
'

# scan_pem FILE [OUT] -> sets SCAN_TOTAL, SCAN_HITS, SCAN_LABELS
scan_pem() {
	r=$(awk -v blocklist="$WORK/blocklist" -v out="${2:-}" "$FILTER_AWK" "$1") || return 1
	read -r SCAN_TOTAL SCAN_HITS SCAN_LABELS <<EOF
$r
EOF
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

[ "$QUIET" -eq 1 ] || explain

# Plan lines: ACTION|path|detail
#   remove    file containing only affected certificates
#   filter    bundle; rewritten without the affected certificates
#   unlink    symlink to a removed file
#   deselect  ca-certificates.conf entry for an affected root (Debian)
: > "$WORK/plan"
: > "$WORK/removed"

find "$SSL_DIR" -type f > "$WORK/files"
while IFS= read -r f; do
	grep -q -e '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null || continue
	scan_pem "$f" || die "failed to scan $f"
	[ "$SCAN_HITS" -gt 0 ] || continue
	if [ "$SCAN_HITS" -eq "$SCAN_TOTAL" ]; then
		echo "remove|$f|$SCAN_LABELS" >> "$WORK/plan"
		echo "$f" >> "$WORK/removed"
	else
		echo "filter|$f|$SCAN_HITS of $SCAN_TOTAL certs: $SCAN_LABELS" >> "$WORK/plan"
	fi
done < "$WORK/files"

# Hash symlinks (e.g. 14bc7599.0) to removed files would be left dangling
if [ -s "$WORK/removed" ]; then
	find "$SSL_DIR" -type l > "$WORK/links"
	while IFS= read -r l; do
		t=$(readlink -f "$l" 2>/dev/null) && grep -qxF "$t" "$WORK/removed" &&
			echo "unlink|$l|link to $(basename "$t")" >> "$WORK/plan"
	done < "$WORK/links"
fi

# Debian-style stores select certificates in ca-certificates.conf and rebuild
# /etc/ssl/certs from it with update-ca-certificates, which would put the roots
# back on the next ca-certificates update unless they are deselected there too.
# Only applies to the system store (or when CA_CONF is given explicitly).
DESELECT=0
if [ -n "${CA_CONF:-}" ] || [ "$SSL_DIR" = /etc/ssl ]; then
	CA_CONF=${CA_CONF:-/etc/ca-certificates.conf}
	CA_SHARE=${CA_SHARE:-/usr/share/ca-certificates}
	if [ -f "$CA_CONF" ] && command -v update-ca-certificates >/dev/null 2>&1; then
		while IFS= read -r entry; do
			case "$entry" in ''|'#'*|'!'*) continue ;; esac
			[ -f "$CA_SHARE/$entry" ] || continue
			scan_pem "$CA_SHARE/$entry" || die "failed to scan $CA_SHARE/$entry"
			[ "$SCAN_HITS" -gt 0 ] && [ "$SCAN_HITS" -eq "$SCAN_TOTAL" ] || continue
			echo "deselect|$CA_CONF|$entry" >> "$WORK/plan"
			echo "$entry" >> "$WORK/deselect"
			DESELECT=1
		done < "$CA_CONF"
	fi
fi

if [ ! -s "$WORK/plan" ]; then
	echo "No compromised eMudhra-linked CA certificates found under $SSL_DIR."
	exit 0
fi

echo "Affected certificate files under $SSL_DIR:"
while IFS='|' read -r action path detail; do
	printf '  %-8s %s\n           %s\n' "$action" "$path" "$detail"
done < "$WORK/plan"
echo

[ "$CHECK_ONLY" -eq 0 ] || exit 2

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------

if [ "$ASSUME_YES" -ne 1 ]; then
	[ -t 0 ] || die "stdin is not a terminal; re-run with --yes to proceed non-interactively"
	printf 'Remove these certificates from the trust store? [y/N] '
	read -r ans || ans=
	case "$ans" in
	y|Y|yes|YES|Yes) ;;
	*) echo "Aborted; no changes made."; exit 3 ;;
	esac
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Back up every path the plan touches; symlinks are archived as links
BACKUP="$BACKUP_PARENT/emudhra-certs-backup-$(date +%Y%m%d-%H%M%S).tar"
cut -d'|' -f2 "$WORK/plan" | sort -u > "$WORK/backup-list"
# Not every BusyBox tar supports -T, so pass the paths as arguments
set --
while IFS= read -r p; do
	set -- "$@" "$p"
done < "$WORK/backup-list"
(umask 077 && tar -cf "$BACKUP" "$@" 2>/dev/null) ||
	die "cannot write backup $BACKUP; no changes made"

fail=0
while IFS='|' read -r action path detail; do
	case "$action" in
	remove|unlink)
		if rm -f "$path"; then
			echo "removed   $path"
		else
			echo "FAILED    $path" >&2
			fail=1
		fi
		;;
	filter)
		# Build the new bundle next to the original (same filesystem, same
		# permissions via cp -p), verify it, then rename it into place so a
		# failure can never leave a truncated bundle behind.
		new="$path.emudhra-new.$$"
		if cp -p "$path" "$new" &&
			scan_pem "$path" "$new" &&
			old_total=$SCAN_TOTAL && old_hits=$SCAN_HITS &&
			scan_pem "$new" &&
			[ "$SCAN_HITS" -eq 0 ] &&
			[ "$SCAN_TOTAL" -eq $((old_total - old_hits)) ] &&
			mv -f "$new" "$path"; then
			echo "edited    $path (removed $old_hits of $old_total certs)"
		else
			rm -f "$new"
			echo "FAILED    $path" >&2
			fail=1
		fi
		;;
	esac
done < "$WORK/plan"

if [ "$DESELECT" -eq 1 ]; then
	# Prefix each entry with "!", which update-ca-certificates treats as
	# deselected; it then drops the links and rebuilds the bundle without them.
	new="$CA_CONF.emudhra-new.$$"
	if cp -p "$CA_CONF" "$new" &&
		awk 'NR == FNR { d[$0] = 1; next } ($0 in d) { print "!" $0; next } { print }' \
			"$WORK/deselect" "$CA_CONF" > "$new" &&
		mv -f "$new" "$CA_CONF"; then
		sed 's/^/deselected /' "$WORK/deselect"
		update-ca-certificates || {
			echo "FAILED    update-ca-certificates" >&2
			fail=1
		}
	else
		rm -f "$new"
		echo "FAILED    $CA_CONF" >&2
		fail=1
	fi
fi

sync

echo
echo "Backup: $BACKUP"
if [ "$DESELECT" -eq 1 ]; then
	echo "Restore with: tar -xf $BACKUP -C / && update-ca-certificates"
else
	echo "Restore with: tar -xf $BACKUP -C /"
fi
echo "Restart long-running services that use TLS (or reboot) so they reload"
echo "the trust store."

[ "$fail" -eq 0 ] || die "one or more files could not be changed; see above"
exit 0
REMOVE_EMUDHRA_CERTS_EOF
}

main
