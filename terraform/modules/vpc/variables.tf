variable "environment"          { type = string }
variable "vpc_cidr"              { type = string }
variable "availability_zones"   { type = list(string) }
variable "public_subnet_cidrs"  { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "app_port"             { type = number; default = 3000 }
