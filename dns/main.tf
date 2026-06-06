terraform {
  required_providers {
    namecheap = {
      source  = "namecheap/namecheap"
      version = "~> 2.0"
    }
  }
}

provider "namecheap" {
  user_name   = var.namecheap_user
  api_user    = var.namecheap_user
  api_key     = var.namecheap_api_key
  client_ip   = var.client_ip
  use_sandbox = false
}

resource "namecheap_domain_records" "imagineering_cc" {
  domain = "imagineering.cc"
  mode   = "OVERWRITE"

  # Bare domain
  record {
    hostname = "@"
    type     = "A"
    address  = var.server_ip
  }

  # Wildcard — catches all subdomains (outline, kan, storage, dav)
  record {
    hostname = "*"
    type     = "A"
    address  = var.server_ip
  }

  # gateway — specific override of the wildcard; points at Robin's OCI
  # (robins-oci, ap-melbourne-1) which hosts the NFTmarket gateway stack.
  record {
    hostname = "gateway"
    type     = "A"
    address  = var.robin_oci_ip
  }

  # SPF — authorize Brevo (Sendinblue) to send email for this domain
  record {
    hostname = "@"
    type     = "TXT"
    address  = "v=spf1 include:sendinblue.com ~all"
  }

  # DMARC — basic policy (monitor mode)
  record {
    hostname = "_dmarc"
    type     = "TXT"
    address  = "v=DMARC1; p=none;"
  }

  # Brevo domain verification — added manually in the dashboard; captured
  # here so OVERWRITE mode doesn't delete it (would break email sending).
  record {
    hostname = "@"
    type     = "TXT"
    address  = "brevo-code:8ebdc1992c17dcab701f4b147022a6a3"
  }

  # Brevo DKIM — signing keys for outbound mail; preserve under OVERWRITE.
  record {
    hostname = "brevo1._domainkey"
    type     = "CNAME"
    address  = "b1.imagineering-cc.dkim.brevo.com."
  }

  record {
    hostname = "brevo2._domainkey"
    type     = "CNAME"
    address  = "b2.imagineering-cc.dkim.brevo.com."
  }
}
