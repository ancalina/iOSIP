#!/usr/bin/env python3
import hashlib
import plistlib
import random
import re
import socket
import sys
import threading
import time
from pathlib import Path

from outgoing_probe import media_destination, run_rtp


def header(message, name):
    match = re.search(rf"(?im)^{re.escape(name)}:\s*(.+?)\r?$", message)
    return match.group(1).strip() if match else ""


def headers(message, name):
    return re.findall(rf"(?im)^{re.escape(name)}:\s*(.+?)\r?$", message)


def parameter(value, name):
    match = re.search(rf'(?:^|[,;\s]){name}="?([^",;\s]+)', value)
    return match.group(1) if match else ""


def md5(value):
    return hashlib.md5(value.encode("utf-8")).hexdigest()


def request(method, uri, via, from_value, to_value, call_id, cseq,
            contact, authorization="", body="", routes=()):
    lines = [
        f"{method} {uri} SIP/2.0",
        f"Via: {via}",
        "Max-Forwards: 70",
        f"From: {from_value}",
        f"To: {to_value}",
        f"Call-ID: {call_id}",
        f"CSeq: {cseq} {method}",
        f"Contact: {contact}",
    ]
    lines[2:2] = [f"Route: {route}" for route in routes]
    if authorization:
        lines.append(f"Authorization: {authorization}")
    if body:
        lines.append("Content-Type: application/sdp")
    lines.append(f"Content-Length: {len(body.encode('utf-8'))}")
    return "\r\n".join(lines) + "\r\n\r\n" + body


def response(request_message, status, reason, contact):
    lines = [f"SIP/2.0 {status} {reason}"]
    lines.extend(
        f"Via: {value}" for value in headers(request_message, "Via")
    )
    lines.extend([
        f"From: {header(request_message, 'From')}",
        f"To: {header(request_message, 'To')}",
        f"Call-ID: {header(request_message, 'Call-ID')}",
        f"CSeq: {header(request_message, 'CSeq')}",
        f"Contact: {contact}",
        "Content-Length: 0",
    ])
    return "\r\n".join(lines) + "\r\n\r\n"


def uri(value):
    match = re.search(r"<([^>]+)>", value)
    return match.group(1) if match else value.split(";", 1)[0]


def receive(sock, deadline):
    while time.monotonic() < deadline:
        sock.settimeout(max(0.1, deadline - time.monotonic()))
        try:
            return sock.recvfrom(65535)[0].decode("utf-8", "replace")
        except socket.timeout:
            pass
    raise TimeoutError("SIP response timeout")


def main():
    with Path("config/device.plist").open("rb") as source:
        config = plistlib.load(source)

    server = config["Server"]
    port = int(config["Port"])
    username = config["Username"]
    caller = sys.argv[1] if len(sys.argv) > 1 else username
    answer = len(sys.argv) > 2 and sys.argv[2] == "answer"
    remote_end = len(sys.argv) > 3 and sys.argv[3] == "remote-end"
    password = config["Password"]
    target = f"sip:{username}@{server}:{port}"
    server_address = (socket.gethostbyname(server), port)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.connect(server_address)
    local_ip = sock.getsockname()[0]
    local_port = sock.getsockname()[1]
    tag = f"{random.getrandbits(48):012x}"
    call_id = f"probe-{random.getrandbits(64):016x}@{local_ip}"
    from_value = f"<sip:{caller}@{server}>;tag={tag}"
    to_value = f"<sip:{username}@{server}>"
    contact = f"<sip:{caller}@{local_ip}:{local_port}>"
    branch = f"z9hG4bK-{random.getrandbits(64):016x}"
    via = f"SIP/2.0/UDP {local_ip}:{local_port};branch={branch};rport"
    rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rtp.bind(("", 0))
    rtp_port = rtp.getsockname()[1]

    first = request("INVITE", target, via, from_value, to_value,
                    call_id, 1, contact)
    sock.sendto(first.encode(), server_address)
    challenge = receive(sock, time.monotonic() + 5)
    if not challenge.startswith("SIP/2.0 401"):
        raise RuntimeError(challenge.splitlines()[0])

    authenticate = header(challenge, "WWW-Authenticate")
    print(challenge.splitlines()[0])
    print(authenticate)
    realm = parameter(authenticate, "realm")
    nonce = parameter(authenticate, "nonce")
    qop = parameter(authenticate, "qop")
    cnonce = f"{random.getrandbits(64):016x}"
    nc = "00000001"
    ha1 = md5(f"{caller}:{realm}:{password}")
    ha2 = md5(f"INVITE:{target}")
    if qop:
        digest = md5(f"{ha1}:{nonce}:{nc}:{cnonce}:{qop}:{ha2}")
    else:
        digest = md5(f"{ha1}:{nonce}:{ha2}")
    authorization = (
        f'Digest username="{caller}", realm="{realm}", nonce="{nonce}", '
        f'uri="{target}", response="{digest}", algorithm=MD5'
    )
    if qop:
        authorization += f', qop={qop}, nc={nc}, cnonce="{cnonce}"'

    branch = f"z9hG4bK-{random.getrandbits(64):016x}"
    via = f"SIP/2.0/UDP {local_ip}:{local_port};branch={branch};rport"
    body = (
        "v=0\r\n"
        f"o=probe 1 1 IN IP4 {local_ip}\r\n"
        "s=IOSIP probe\r\n"
        f"c=IN IP4 {local_ip}\r\n"
        "t=0 0\r\n"
        f"m=audio {rtp_port} RTP/AVP 0 8 101\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=rtpmap:8 PCMA/8000\r\n"
        "a=rtpmap:101 telephone-event/8000\r\n"
        "a=fmtp:101 0-15\r\n"
        "a=sendrecv\r\n"
    )
    invite = request("INVITE", target, via, from_value, to_value,
                     call_id, 2, contact, authorization, body)
    sock.sendto(invite.encode(), server_address)

    deadline = time.monotonic() + (30 if answer else 10)
    statuses = []
    ringing = None
    accepted = None
    rejected = None
    while time.monotonic() < deadline:
        try:
            response_message = receive(sock, deadline)
        except TimeoutError:
            break
        status = response_message.splitlines()[0]
        statuses.append(status)
        if status.startswith(("SIP/2.0 180", "SIP/2.0 183")):
            ringing = response_message
            if not answer:
                break
        if status.startswith("SIP/2.0 200"):
            accepted = response_message
            break
        if status.startswith(("SIP/2.0 4", "SIP/2.0 5",
                              "SIP/2.0 6")):
            rejected = status
            break
    if rejected:
        print("\n".join(statuses), flush=True)
        return

    if answer:
        if not accepted:
            raise TimeoutError("no 200 response to INVITE")
        destination = media_destination(accepted)
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
        rtp_stop = threading.Event()
        rtp_counts = {"sent": 0, "received": 0}
        rtp_thread = None
        if destination:
            rtp_thread = threading.Thread(
                target=run_rtp,
                args=(rtp, destination, rtp_stop, rtp_counts),
                daemon=True,
            )
            rtp_thread.start()
        ack_branch = f"z9hG4bK-{random.getrandbits(64):016x}"
        ack_via = (
            f"SIP/2.0/UDP {local_ip}:{local_port};"
            f"branch={ack_branch};rport"
        )
        routes = tuple(reversed(headers(accepted, "Record-Route")))
        ack = request(
            "ACK",
            uri(header(accepted, "Contact")) or target,
            ack_via,
            from_value,
            header(accepted, "To"),
            call_id,
            2,
            contact,
            routes=routes,
        )
        sock.sendto(ack.encode(), server_address)
        print("\n".join(statuses), flush=True)
        print("CONNECTED", flush=True)
        try:
            if remote_end:
                time.sleep(8)
                bye_branch = f"z9hG4bK-{random.getrandbits(64):016x}"
                bye_via = (
                    f"SIP/2.0/UDP {local_ip}:{local_port};"
                    f"branch={bye_branch};rport"
                )
                bye = request(
                    "BYE",
                    uri(header(accepted, "Contact")) or target,
                    bye_via,
                    from_value,
                    header(accepted, "To"),
                    call_id,
                    3,
                    contact,
                    routes=routes,
                )
                sock.sendto(bye.encode(), server_address)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    reply = receive(sock, deadline)
                    if (reply.startswith("SIP/2.0 200") and
                            header(reply, "CSeq").endswith("BYE")):
                        print("REMOTE BYE OK", flush=True)
                        return
                raise TimeoutError("no 200 response to BYE")
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                message = receive(sock, deadline)
                first = message.splitlines()[0]
                if first.startswith("BYE "):
                    sock.sendto(
                        response(message, 200, "OK", contact).encode(),
                        server_address,
                    )
                    print("RECEIVED BYE", flush=True)
                    return
            raise TimeoutError("no BYE")
        finally:
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

    cancel_to = header(ringing, "To") if ringing else to_value
    cancel = request("CANCEL", target, via, from_value, cancel_to,
                     call_id, 2, contact)
    sock.sendto(cancel.encode(), server_address)
    print("\n".join(statuses))


if __name__ == "__main__":
    main()
