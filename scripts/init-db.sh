#!/bin/bash
set -e

if [ -z "$SUPABASE_URL" ]; then
  echo "⚠️  SUPABASE_URL not set — skipping Supabase migration."
  echo "   The BE seed script will populate the database instead."
  exit 0
fi

echo "========================================"
echo " First-time DB setup — migrating from Supabase"
echo "========================================"

pg_dump --no-owner --no-acl "$SUPABASE_URL" | psql -U talentos -d talentos

echo "========================================"
echo " Migration complete."
echo "========================================"
