terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Dataform ainda exige o provedor beta para algumas funcionalidades
provider "google-beta" {
  project = var.project_id
  region  = var.region
}