# Least-privilege policy for the talentOS backend token.
# The app token can only READ the secret paths the backend consumes —
# it cannot write, list, or read anything else.
#   talentos/* = UAT/deployed stack (server .env)
#   dev/*      = local dev (DEV_* overrides, e.g. local Supabase URL)
path "secret/data/talentos/*" {
  capabilities = ["read"]
}

path "secret/data/dev/*" {
  capabilities = ["read"]
}
