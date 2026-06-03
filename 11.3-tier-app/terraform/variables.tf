variable "resource_group_name" {
  type    = string
  default = "3tier-rg"
}

variable "location" {
  type    = string
  default = "Central India"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "key_vault_name" {
  description = "Globally unique Key Vault name (3-24 chars)"
  type        = string
}

variable "postgres_server_name" {
  description = "Globally unique PostgreSQL server name"
  type        = string
}

variable "db_admin_user" {
  type    = string
  default = "pgadmin"
}

variable "db_admin_password" {
  description = "PostgreSQL admin password — use a strong password"
  type        = string
  sensitive   = true
}

variable "my_ip" {
  description = "Your public IP for jump box SSH (x.x.x.x/32)"
  type        = string
}
