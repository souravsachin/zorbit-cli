#!/usr/bin/env bash
# =============================================================================
# scripts/adapters/auth_provider/manual.sh
#
# Auth provider — MANUAL. Trusts the operator to be authenticated.
# =============================================================================

auth_check() { return 0; }
auth_fix()   { return 0; }
auth_required_scopes_default() { echo ""; }
