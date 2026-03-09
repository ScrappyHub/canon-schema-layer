# CSL NFL Packet Lock

Status: GREEN / LOCKED

Canonical latest green bundle:
- C:\dev\csl\proofs\receipts\20260308T231314Z

Frozen bundle:
- C:\dev\csl\test_vectors\tier0_frozen\csl_nfl_packet_green_20260308

Canonical locked scripts:
- scripts/csl_emit_nfl_packet_v1.ps1
- scripts/verify_csl_nfl_packet_v1.ps1
- scripts/selftest_csl_nfl_packet_v1.ps1

Locked packet root:
- C:\dev\csl\test_vectors\csl_nfl_packet_v1\minimal_valid\packet

Locked positive hashes:
- MANIFEST_SHA256=1ef837c359d7f6b6558c01918f9cbdd31c4aa59ad9379ef8a472da8d486a0585
- SHA256SUMS_SHA256=b4cef74ea3ea6e727aa0e01ab3edfefff4a3ea6807d62e0f36f915740b79480a

Tier-0 integration claim:
- CSL emits an NFL-style packet deterministically
- CSL verifies that packet deterministically
- selftest emits deterministic receipt bundle
- bundle sha256 evidence is generated
- locked surfaces parse-gate under PS5.1 StrictMode
