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
}
