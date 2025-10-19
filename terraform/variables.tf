
variable "project" {
  type    = string
  default = "civicpulse"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "location" {
  type    = string
  default = "uksouth"
}

variable "pg_admin_user" {
  type = string
}

variable "pg_admin_pwd" {
  type      = string
  sensitive = true
}

variable "vnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "subnet_pg" {
  type    = string
  default = "10.10.1.0/24"
}

variable "subnet_pe" {
  type    = string
  default = "10.10.2.0/24"
}
