# Least-privilege policy for the talentOS AI-service token.
# Read-only access to exactly the secrets the AI service consumes.
#   ai/*     = UAT/deployed stack (server .env)
#   ai-dev/* = local dev (DEV_* overrides)
path "secret/data/ai/*" {
  capabilities = ["read"]
}

path "secret/data/ai-dev/*" {
  capabilities = ["read"]
}
