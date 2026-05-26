# AppRole auth — role-id is written at deploy time (not secret),
# secret-id is delivered once at bootstrap and consumed immediately.
auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/etc/bao/role-id"
      secret_id_file_path                 = "/etc/bao/secret-id"
      remove_secret_id_file_after_reading = true
    }
  }

  # Persistent cache — agent reads this on restart and renews it instead of
  # re-authenticating. Without this, every reboot consumes a new secret-id.
  sink "file" {
    config = {
      path = "/etc/bao/token-cache"
      mode = 0400
    }
  }
}
