output "dataform_console_url" {
  value       = "https://console.cloud.google.com/bigquery/dataform/locations/${var.region}/repositories/${google_dataform_repository.martech_repo.name}/details?project=${var.project_id}"
  description = "Link direto para o repositório Dataform no GCP"
}