# OpenBao server configuration (single node, file storage).
# Secrets are encrypted at rest inside the `bao-data` volume.

ui = true

storage "file" {
  path = "/bao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Used for internal CLI/API addressing. The app talks to `http://openbao:8200`
# via the compose network and is not given the admin token.
api_addr = "http://127.0.0.1:8200"

log_level = "info"
