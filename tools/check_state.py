#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
history_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None

with state_path.open("rb") as stream:
    state = plistlib.load(stream)
history = []
if history_path:
    with history_path.open("rb") as stream:
        history = plistlib.load(stream)

assert state["state"] in {
    "idle", "incoming", "calling", "connected", "ended"
}
assert isinstance(state["registered"], bool)
assert isinstance(state["generation"], int)

if "last_end" in state:
    last_end = state["last_end"]
    assert {"generation", "remote", "status", "reason", "time"} <= last_end.keys()
    if "call_id" in last_end:
        assert "started_at" in last_end

if state["state"] not in {"idle", "ended"}:
    assert state["call_id"]
    assert state["direction"] in {"incoming", "outgoing"}
    assert "started_at" in state
if state["state"] == "connected":
    assert "connected_at" in state

for value in (state, state.get("last_end", {})):
    media = value.get("media")
    if not media:
        continue
    assert {
        "status", "direction", "conference_slot", "sound_active",
        "sound_device_status",
    } <= media.keys()
    assert media.get("tx_packets", 0) >= 0
    assert media.get("rx_packets", 0) >= 0

assert len(history) <= 100
assert len({call["call_id"] for call in history}) == len(history)
for call in history:
    assert {
        "call_id", "direction", "remote", "started_at", "status",
        "reason", "time",
    } <= call.keys()
    assert call["direction"] in {"incoming", "outgoing"}

print(
    f"state={state['state']} generation={state['generation']} "
    f"history={len(history)} last_end={'last_end' in state}"
)
