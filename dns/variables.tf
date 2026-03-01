variable "namecheap_user" {
  description = "Namecheap account username"
  type        = string
}

variable "namecheap_api_key" {
  description = "Namecheap API key"
  type        = string
  sensitive   = true
}

variable "client_ip" {
  description = "Your current public IP (must be whitelisted in Namecheap API settings)"
  type        = string
}

variable "server_ip" {
  description = "GCE instance static IP"
  type        = string
  default     = "34.40.229.206"
}
