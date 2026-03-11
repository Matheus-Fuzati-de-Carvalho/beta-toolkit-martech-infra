terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0" # Ou a versão que você preferir
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "us-east1"
}

provider "google-beta" {
  project = var.project_id
  region  = "us-east1"
}