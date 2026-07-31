#!/usr/bin/env python3
import hashlib
import audioop
import plistlib
import random
import re
import socket
import struct
import sys
import threading
import time
from pathlib import Path


def header(message, name):
    match = re.search(rf"(?im)^{re.escape(name)}:\s*(.+?)\r?$", message)
    return match.group(1).strip() if match else ""


def headers(message, name):
    return re.findall(rf"(?im)^{re.escape(name)}:\s*(.+?)\r?$", message)


def parameter(value, name):
    match = re.search(rf'(?:^|[,;\s]){name}="?([^",;\s]+)', value)
    return match.group(1) if match else ""


def uri(value):
    match = re.search(r"<([^>]+)>", value)
    return match.group(1) if match else value.split(";", 1)[0]


def media_destination(message):
    body = message.partition("\r\n\r\n")[2]
    address = re.search(r"(?im)^c=IN IP4\s+(\S+)\r?$", body)
    port = re.search(r"(?im)^m=audio\s+(\d+)\s", body)
    if not address or not port:
        return None
    return address.group(1), int(port.group(1))


def run_rtp(sock, destination, stop, counts):
    sock.setblocking(False)
    sequence = random.randrange(65536)
    timestamp = random.randrange(2**32)
    ssrc = random.randrange(2**32)
    next_send = time.monotonic()
    first = True
    while not stop.is_set():
        while True:
            try:
                packet, _ = sock.recvfrom(65535)
                if len(packet) >= 12:
                    counts["received"] += 1
                    payload_type = packet[1] & 0x7f
                    if payload_type == 0:
                        rms = audioop.rms(
                            audioop.ulaw2lin(packet[12:], 2), 2
                        )
                        counts["peak_rms"] = max(
                            rms, counts.get("peak_rms", 0)
                        )
                    elif payload_type == 101 and len(packet) >= 16:
                        counts.setdefault("dtmf", set()).add(packet[12])
            except BlockingIOError:
                break
        now = time.monotonic()
        if now >= next_send:
            marker_payload = 0x80 if first else 0
            packet = struct.pack(
                "!BBHII", 0x80, marker_payload, sequence,
                timestamp, ssrc
            ) + (b"\x9c" * 10 + b"\x1c" * 10) * 8
            sock.sendto(packet, destination)
            counts["sent"] += 1
            sequence = (sequence + 1) & 0xFFFF
            timestamp = (timestamp + 160) & 0xFFFFFFFF
            next_send += 0.02
            first = False
        stop.wait(max(0, min(0.01, next_send - time.monotonic())))


def digest(method, uri, username, password, challenge):
    realm = parameter(challenge, "realm")
    nonce = parameter(challenge, "nonce")
    qop = parameter(challenge, "qop")
    cnonce = f"{random.getrandbits(64):016x}"
    nc = "00000001"
    ha1 = hashlib.md5(
        f"{username}:{realm}:{password}".encode()
    ).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    if qop:
        response = hashlib.md5(
            f"{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}".encode()
        ).hexdigest()
    else:
        response = hashlib.md5(
            f"{ha1}:{nonce}:{ha2}".encode()
        ).hexdigest()
    value = (
        f'Digest username="{username}", realm="{realm}", nonce="{nonce}", '
        f'uri="{uri}", response="{response}", algorithm=MD5'
    )
    if qop:
        value += f', qop={qop}, nc={nc}, cnonce="{cnonce}"'
    return value


def register(sock, server_address, server, port, username, password,
             local_ip, local_port):
    registrar = f"sip:{server}:{port}"
    identity = f"<sip:{username}@{server}>"
    contact = f"<sip:{username}@{local_ip}:{local_port}>"
    tag = f"{random.getrandbits(48):012x}"
    call_id = f"register-{random.getrandbits(64):016x}@{local_ip}"

    def message(cseq, authorization=""):
        branch = f"z9hG4bK-{random.getrandbits(64):016x}"
        lines = [
            f"REGISTER {registrar} SIP/2.0",
            f"Via: SIP/2.0/UDP {local_ip}:{local_port};"
            f"branch={branch};rport",
            "Max-Forwards: 70",
            f"From: {identity};tag={tag}",
            f"To: {identity}",
            f"Call-ID: {call_id}",
            f"CSeq: {cseq} REGISTER",
            f"Contact: {contact}",
            "Expires: 600",
        ]
        if authorization:
            lines.append(f"Authorization: {authorization}")
        lines.append("Content-Length: 0")
        return "\r\n".join(lines) + "\r\n\r\n"

    sock.sendto(message(1).encode(), server_address)
    challenge_message, _ = sock.recvfrom(65535)
    challenge_message = challenge_message.decode("utf-8", "replace")
    if not challenge_message.startswith("SIP/2.0 401"):
        raise RuntimeError(challenge_message.splitlines()[0])
    authorization = digest(
        "REGISTER", registrar, username, password,
        header(challenge_message, "WWW-Authenticate")
    )
    sock.sendto(message(2, authorization).encode(), server_address)
    deadline = time.monotonic() + 5
    while True:
        packet, source = sock.recvfrom(65535)
        reply = packet.decode("utf-8", "replace")
        first = reply.splitlines()[0]
        if first.startswith("OPTIONS "):
            sock.sendto(response(reply, 200, "OK", contact).encode(),
                        source)
            continue
        if first.startswith("SIP/2.0 200"):
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(first)
    granted = (
        parameter(header(reply, "Contact"), "expires")
        or header(reply, "Expires")
        or "unknown"
    )
    print(f"REGISTERED expires={granted}", flush=True)


def response(request, status, reason, contact, body="", to_tag=""):
    to_value = header(request, "To")
    if "tag=" not in to_value:
        tag = to_tag or f"{random.getrandbits(48):012x}"
        to_value += f";tag={tag}"
    lines = [f"SIP/2.0 {status} {reason}"]
    lines.extend(f"Via: {value}" for value in headers(request, "Via"))
    lines.extend(
        f"Record-Route: {value}"
        for value in headers(request, "Record-Route")
    )
    lines.extend([
        f"From: {header(request, 'From')}",
        f"To: {to_value}",
        f"Call-ID: {header(request, 'Call-ID')}",
        f"CSeq: {header(request, 'CSeq')}",
        f"Contact: {contact}",
    ])
    if body:
        lines.append("Content-Type: application/sdp")
    lines.append(f"Content-Length: {len(body.encode())}")
    return "\r\n".join(lines) + "\r\n\r\n" + body


def dialog_request(method, request_uri, via, from_value, to_value,
                   call_id, cseq, contact, routes):
    lines = [
        f"{method} {request_uri} SIP/2.0",
        f"Via: {via}",
        "Max-Forwards: 70",
    ]
    lines.extend(f"Route: {route}" for route in routes)
    lines.extend([
        f"From: {from_value}",
        f"To: {to_value}",
        f"Call-ID: {call_id}",
        f"CSeq: {cseq} {method}",
        f"Contact: {contact}",
        "Content-Length: 0",
    ])
    return "\r\n".join(lines) + "\r\n\r\n"


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(
            "usage: outgoing_probe.py TEST_ACCOUNT [remote-end]"
        )
    with Path("config/device.plist").open("rb") as source:
        config = plistlib.load(source)

    server = config["Server"]
    port = int(config["Port"])
    username = sys.argv[1]
    remote_end = len(sys.argv) == 3 and sys.argv[2] == "remote-end"
    password = config["Password"]
    server_address = (socket.gethostbyname(server), port)

    route = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    route.connect(server_address)
    local_ip = route.getsockname()[0]
    route.close()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.settimeout(90)
    local_port = sock.getsockname()[1]
    contact = f"<sip:{username}@{local_ip}:{local_port}>"
    register(sock, server_address, server, port, username, password,
             local_ip, local_port)

    rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rtp.bind(("", 0))
    rtp_port = rtp.getsockname()[1]
    rtp_stop = threading.Event()
    rtp_counts = {"sent": 0, "received": 0}
    rtp_thread = None
    invite = None
    dialog_tag = f"{random.getrandbits(48):012x}"
    while True:
        packet, source = sock.recvfrom(65535)
        message = packet.decode("utf-8", "replace")
        first = message.splitlines()[0]
        method = first.split(" ", 1)[0]
        if method == "INVITE":
            invite = message
            print(
                f"RECEIVED {first} CSeq={header(message, 'CSeq')}",
                flush=True,
            )
            sock.sendto(response(message, 180, "Ringing", contact,
                                 to_tag=dialog_tag).encode(),
                        source)
            body = (
                "v=0\r\n"
                f"o=probe 1 1 IN IP4 {local_ip}\r\n"
                "s=IOSIP outgoing probe\r\n"
                f"c=IN IP4 {local_ip}\r\n"
                "t=0 0\r\n"
                f"m=audio {rtp_port} RTP/AVP 0 8 101\r\n"
                "a=rtpmap:0 PCMU/8000\r\n"
                "a=rtpmap:8 PCMA/8000\r\n"
                "a=rtpmap:101 telephone-event/8000\r\n"
                "a=fmtp:101 0-15\r\n"
                "a=sendrecv\r\n"
            )
            sock.sendto(response(message, 200, "OK", contact, body,
                                 dialog_tag).encode(),
                        source)
            destination = media_destination(message)
            advertised_destination = destination
            media_host = config.get("MediaHost")
            if destination and media_host:
                destination = (
                    socket.gethostbyname(media_host),
                    destination[1],
                )
            print(
                f"RTP advertised={advertised_destination} "
                f"target={destination}",
                flush=True,
            )
            if destination:
                if rtp_thread:
                    rtp_stop.set()
                    rtp_thread.join(1)
                    rtp_stop = threading.Event()
                rtp_thread = threading.Thread(
                    target=run_rtp,
                    args=(rtp, destination, rtp_stop, rtp_counts),
                    daemon=True,
                )
                rtp_thread.start()
        elif method == "ACK":
            print("RECEIVED ACK", flush=True)
            if remote_end:
                time.sleep(3)
                branch = f"z9hG4bK-{random.getrandbits(64):016x}"
                via = (
                    f"SIP/2.0/UDP {local_ip}:{local_port};"
                    f"branch={branch};rport"
                )
                from_value = header(invite, "To")
                if "tag=" not in from_value:
                    from_value += f";tag={dialog_tag}"
                bye = dialog_request(
                    "BYE",
                    uri(header(invite, "Contact")),
                    via,
                    from_value,
                    header(invite, "From"),
                    header(invite, "Call-ID"),
                    1,
                    contact,
                    headers(invite, "Record-Route"),
                )
                sock.sendto(bye.encode(), server_address)
        elif (first.startswith("SIP/2.0 200") and
              header(message, "CSeq").endswith("BYE")):
            print("REMOTE BYE OK", flush=True)
            rtp_stop.set()
            if rtp_thread:
                rtp_thread.join(1)
            print(
                f"RTP sent={rtp_counts['sent']} "
                f"received={rtp_counts['received']} "
                f"peak_rms={rtp_counts.get('peak_rms', 0)} "
                f"dtmf={sorted(rtp_counts.get('dtmf', ())) or '-'}",
                flush=True,
            )
            return
        elif method == "BYE":
            print("RECEIVED BYE", flush=True)
            print(
                "BYE",
                f"source={source[0]}:{source[1]}",
                f"from={header(message, 'From')}",
                f"reason={header(message, 'Reason') or '-'}",
                f"user-agent={header(message, 'User-Agent') or '-'}",
                flush=True,
            )
            sock.sendto(response(message, 200, "OK", contact).encode(),
                        source)
            rtp_stop.set()
            if rtp_thread:
                rtp_thread.join(1)
            print(
                f"RTP sent={rtp_counts['sent']} "
                f"received={rtp_counts['received']} "
                f"peak_rms={rtp_counts.get('peak_rms', 0)} "
                f"dtmf={sorted(rtp_counts.get('dtmf', ())) or '-'}",
                flush=True,
            )
            return
        elif method == "CANCEL" and invite:
            sock.sendto(response(message, 200, "OK", contact).encode(),
                        source)
            sock.sendto(response(invite, 487, "Request Terminated",
                                 contact).encode(), source)
            return


def self_check():
    sample = (
        "INVITE sip:test SIP/2.0\r\nContent-Length: 53\r\n\r\n"
        "c=IN IP4 192.0.2.1\r\nm=audio 4000 RTP/AVP 0\r\n"
    )
    assert media_destination(sample) == ("192.0.2.1", 4000)
    assert audioop.rms(audioop.ulaw2lin(b"\xff" * 160, 2), 2) == 0
    assert audioop.rms(
        audioop.ulaw2lin((b"\x9c" * 10 + b"\x1c" * 10) * 8, 2), 2
    ) > 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        self_check()
    else:
        main()
