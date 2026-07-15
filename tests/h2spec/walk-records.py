#!/usr/bin/env python3
# walk-records.py <pcap> <server_port> — reassembla o stream SERVIDOR->CLIENTE
# (TCP.sport==server_port) por numero de sequencia (dedup de retransmissao/overlap
# do loopback) e caminha os headers de record TLS de 5 bytes:
#   [type(1)][version(2)=0x0303][length(2)]
# Reporta o 1o offset onde type nao in {20,21,22,23} ou version != 0x0303 = DESYNC.
import sys
from scapy.all import rdpcap, TCP, IP

pcap, sport = sys.argv[1], int(sys.argv[2])
pkts = rdpcap(pcap)

# coletar segmentos servidor->cliente: (seq, payload)
segs = {}
for p in pkts:
    if TCP in p and p[TCP].sport == sport:
        raw = bytes(p[TCP].payload)
        if raw:
            segs.setdefault(p[TCP].seq, raw)  # 1a ocorrencia por seq (dedup)

if not segs:
    print("sem segmentos servidor->cliente"); sys.exit(0)

# reassemblar por seq crescente, tratando overlap (avancar pelo maior end visto)
seqs = sorted(segs)
base = seqs[0]
stream = bytearray()
next_seq = base
for s in seqs:
    end = s + len(segs[s])
    if end <= next_seq:
        continue                      # totalmente contido/retransmissao
    start_off = next_seq - s if s < next_seq else 0
    stream += segs[s][start_off:]
    next_seq = max(next_seq, end)

data = bytes(stream)
print(f"stream servidor->cliente: {len(data)} bytes reassemblados ({len(segs)} segmentos)")

TYPES = {20: "ChangeCipherSpec", 21: "Alert", 22: "Handshake", 23: "AppData"}
off = 0
rec = 0
while off + 5 <= len(data):
    t = data[off]
    ver = (data[off+1] << 8) | data[off+2]
    ln = (data[off+3] << 8) | data[off+4]
    if t not in TYPES or ver != 0x0303:
        print(f"DESYNC no record #{rec} offset {off}: type={t} ver={ver:04x} len={ln}")
        ctx = data[max(0,off-8):off+8]
        print(f"  bytes ao redor: {ctx.hex()}")
        # mostrar o record anterior p/ diagnosticar (len errado? dup? drop?)
        sys.exit(0)
    rec += 1
    off += 5 + ln
print(f"OK: {rec} records TLS limpos, sem desync (consumidos {off}/{len(data)} bytes)")
