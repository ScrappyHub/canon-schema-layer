# CSL

CSL is the canonical conformance / spec-layer instrument.

## Locked NFL Integration

CSL now has a locked deterministic NFL-style packet path.

Canonical locked surface:
- scripts/csl_emit_nfl_packet_v1.ps1
- scripts/verify_csl_nfl_packet_v1.ps1
- scripts/selftest_csl_nfl_packet_v1.ps1
- scripts/_RUN_freeze_csl_nfl_packet_green_v1.ps1

Canonical lock docs:
- docs/CSL_NFL_PACKET_LOCK.md
- docs/CSL_CANONICAL_STATUS.md

Canonical frozen evidence:
- test_vectors/tier0_frozen/csl_nfl_packet_green_20260308

## Locked result

The CSL NFL packet selftest and freeze are GREEN and frozen for Tier-0 integration scope.

## Current scope

This locked scope proves:
- deterministic CSL emit of an NFL-style packet
- deterministic CSL verify of that packet
- deterministic receipt bundle emission
- deterministic frozen evidence bundle
