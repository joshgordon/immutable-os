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

  # Token written here; dependent containers mount /run/secrets read-only.
  sink "file" {
    config = {
      path = "/run/secrets/bao-token"
      mode = 0400
    }
  }
}
