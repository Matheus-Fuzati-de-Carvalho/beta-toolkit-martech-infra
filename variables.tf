variable "project_id" {
  description = "ID do projeto GCP de destino"
  type        = string
}

variable "region" {
  type    = string
  default = "us-east1"
}

variable "github_repo_url" {
  description = "URL do repo SQL (ex: https://github.com/matheus/toolkit-sql.git)"
  type        = string
}

variable "github_token" {
  type      = string
  sensitive = true
}

variable "flavor" {
  description = "Branch: dist-marketing-basic ou dist-retail-media"
  type        = string
}