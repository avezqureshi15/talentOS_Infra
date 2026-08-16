# Least-privilege policy for the talentOS backend token.
# The app token can only READ the secret paths the backend consumes —
# it cannot write, list, or read anything else.
path "secret/data/talentos/*" {
  capabilities = ["read"]
}
