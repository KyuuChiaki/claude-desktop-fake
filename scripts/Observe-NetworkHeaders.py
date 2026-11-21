"""Bounded, receive-only IPv4 header observation; no packet payload is saved."""
import argparse
import ctypes
import json
from pathlib import Path
import select
import socket
import struct
import time

parser = argparse.ArgumentParser()
for name in ['physical', 'tun', 'upstream', 'ready', 'stop', 'output']:
    parser.add_argument('--' + name, required=True)
args = parser.parse_args()
ws2 = ctypes.WinDLL('ws2_32', use_last_error=True)
ws2.recv.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
ws2.recv.restype = ctypes.c_int
channels = {}
errors = {}
records = []
buffer = ctypes.create_string_buffer(40)
try:
    for label, address in [('physical', args.physical), ('tun', args.tun)]:
        channel = None
        try:
            channel = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_IP)
            channel.bind((address, 0))
            channel.ioctl(socket.SIO_RCVALL, 3)  # RCVALL_IPLEVEL; no promiscuous NIC mode.
            channel.setblocking(False)
            channels[channel] = label
        except OSError as error:
            errors[label] = error.winerror
            if channel is not None:
                channel.close()
    Path(args.ready).write_text(json.dumps({'channels': list(channels.values()), 'errors': errors}), encoding='utf-8')
    end = time.monotonic() + 30
    while channels and time.monotonic() < end and not Path(args.stop).exists():
        readable, _, _ = select.select(list(channels), [], [], 0.1)
        for channel in readable:
            ctypes.memset(buffer, 0, 40)
            received = ws2.recv(channel.fileno(), buffer, 40, 0)
            if received < 0 and ws2.WSAGetLastError() != 10040:
                continue  # A truncated datagram still supplies its header prefix.
            header = buffer.raw
            if header[0] != 0x45 or header[9] != socket.IPPROTO_TCP:
                continue
            source, destination = socket.inet_ntoa(header[12:16]), socket.inet_ntoa(header[16:20])
            if args.upstream not in [source, destination]:
                continue
            sport, dport = struct.unpack('!HH', header[20:24])
            records.append({'interface': channels[channel], 'source': source, 'sourcePort': sport,
                            'destination': destination, 'port': dport, 'flags': header[33], 'time': time.time()})
            if len(records) >= 10000:
                end = 0
finally:
    for channel in channels:
        try:
            channel.ioctl(socket.SIO_RCVALL, socket.RCVALL_OFF)
        finally:
            channel.close()
    Path(args.output).write_text(json.dumps({'method': 'SIO_RCVALL_IPLEVEL IPv4/TCP header prefix only',
                                            'channels': list(channels.values()), 'errors': errors,
                                            'records': records}, indent=2), encoding='utf-8')
