template {
  source      = "/etc/bao/templates/cf-rdns.env.tmpl"
  destination = "/run/secrets/cf-rdns.env"
  perms       = "0400"
  command     = "systemctl try-restart cf-rdns"
}

template {
  source      = "/etc/bao/templates/adguardhome-sync.yaml.tmpl"
  destination = "/run/secrets/adguardhome-sync.yaml"
  perms       = "0400"
  command     = "systemctl try-restart adguardhome-sync"
}
