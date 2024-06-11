variable "tfe_license" {
  type        = string
  description = "The license for Terraform Enterprise."
}

variable "tfe_version" {
  type        = string
  description = "The version of Terraform Enterprise to deploy."
  default     = "v202401-2"
}

variable "postgresql_version" {
  type        = string
  description = "The version of the PostgreSQL engine to deploy."
  default     = "15.7"
}

variable "tfe_hostname" {
  type        = string
  description = "The hostname of Terraform Enterprise instance."
  default     = "tfe"
}

variable "tfe_db_name" {
  type        = string
  description = "The name of the database used to store TFE data in."
  default     = "tfe"
}

variable "tfe_db_username" {
  type        = string
  description = "The username used to access the TFE database."
  default     = "tfe_user"
}

variable "vpc_name" {
  type        = string
  description = "The name of the VPC used to host TFE."
  default     = "tfe-vpc"
}

variable "s3_vpc_endpoint_name" {
  type        = string
  description = "The name of the S3 VPC Endpoint."
  default     = "tfe-vpce-s3"
}

variable "bastion_security_group_name" {
  type        = string
  description = "The name of the Bastion Host Security Group."
  default     = "bastion-sg"
}

variable "tfe_security_group_name" {
  type        = string
  description = "The name of the TFE Hosts Security Group."
  default     = "tfe-sg"
}

variable "alb_security_group_name" {
  type        = string
  description = "The name of the Application Load Balancer Security Group."
  default     = "alb-sg"
}

variable "route53_zone_name" {
  type        = string
  description = "The name of the Route53 Zone used to host TFE."
  default     = "craig-sloggett.sbx.hashidemos.io"
}

variable "ec2_iam_role_name" {
  type        = string
  description = "The name of the IAM Role assigned to the EC2 Instance Profile assigned to the TFE hosts."
  default     = "tfe-iam-role"
}

variable "ec2_instance_profile_name" {
  type        = string
  description = "The name of the EC2 Instance Profile assigned to the TFE hosts."
  default     = "tfe-instance-profile"
}

variable "lb_name" {
  type        = string
  description = "The name of the application load balancer used to distribute HTTPS traffic across TFE hosts."
  default     = "tfe-web-alb"
}

variable "lb_target_group_name" {
  type        = string
  description = "The name of the target group used to direct HTTPS traffic to TFE hosts."
  default     = "tfe-web-alb-tg"
}

variable "rds_instance_name" {
  type        = string
  description = "The name of the RDS instance used to externalize TFE services."
  default     = "tfe-postgres-db"
}

variable "rds_instance_master_username" {
  type        = string
  description = "The username of the RDS master user."
  default     = "tfe"
}

variable "rds_instance_class" {
  type        = string
  description = "The instance type (size) of the RDS instance."
  default     = "db.t3.medium"
}

variable "rds_security_group_name" {
  type        = string
  description = "The name of the RDS Security Group."
  default     = "rds-sg"
}

variable "rds_subnet_group_name" {
  type        = string
  description = "The name of the RDS Subnet Group."
  default     = "rds-sg"
}

variable "rds_parameter_group_name" {
  type        = string
  description = "The name of the RDS Parameter Group."
  default     = "rds-pg"
}

variable "elasticache_name" {
  type        = string
  description = "The name of the cache used as the TFE Redis cache."
  default     = "tfe-redis-cache"
}

variable "elasticache_security_group_name" {
  type        = string
  description = "The name of the ElastiCache Security Group."
  default     = "elasticache-sg"
}

variable "elasticache_subnet_group_name" {
  type        = string
  description = "The name of the ElastiCache Subnet Group."
  default     = "elasticache-sg"
}
