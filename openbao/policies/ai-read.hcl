# Least-privilege policy for the talentOS AI-service token.
# Read-only access to exactly the secrets the AI service consumes.
path "secret/data/ai/*" {
  capabilities = ["read"]
}
