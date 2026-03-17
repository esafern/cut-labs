import sys,json

# WIRE fields: actual bits on the packet. Always present.
# COMPUTED fields: derived by tshark. Optional — engine derives if absent.
# See FIELD_REFERENCE.md for derivation formulas.

WIRE = ("src_ip src_port dst_ip dst_port "
        "timestamp_epoch "
        "ttl ip_id ip_len dscp ecn df ip_proto "
        "tcp_flags_hex tcp_flags_str tcp_flags_cwr tcp_flags_ece "
        "seq_raw ack_raw win_value tcp_payload_len tcp_hdr_len urgent_ptr "
        "mss wscale ts_val ts_ecr tcp_options_raw").split()

COMPUTED = ("time_delta frame_len protocols tcp_stream "
            "is_retransmit is_zero_window initial_rtt ack_rtt bytes_in_flight").split()

ALL = WIRE + COMPUTED

I = {"src_port","dst_port","ttl","ip_len","dscp","ecn","ip_proto",
     "win_value","tcp_payload_len","tcp_hdr_len","urgent_ptr","mss",
     "wscale","frame_len","tcp_stream","bytes_in_flight"}

for l in sys.stdin:
    v = l.strip().split(",")
    if len(v) < 4 or not v[0]:
        continue
    k = f"{v[0]}:{v[1]}-{v[2]}:{v[3]}"
    p = {}
    for i, f in enumerate(ALL):
        if i < len(v) and v[i]:
            p[f] = int(v[i]) if f in I else v[i]
    print(f"{k}\t{json.dumps(p)}")
