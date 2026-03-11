# 1. Ativação de APIs
resource "google_project_service" "services" {
  for_each = toset([
    "dataform.googleapis.com",
    "secretmanager.googleapis.com",
    "bigquery.googleapis.com",
    "cloudscheduler.googleapis.com"
  ])
  service = each.key
  disable_on_destroy = false
}

# 2. Secret Manager para o GitHub Token
resource "google_secret_manager_secret" "github_token_secret" {
  secret_id = "github-token-dataform"
  replication { automatic = true }
}

resource "google_secret_manager_secret_version" "github_token_version" {
  secret      = google_secret_manager_secret.github_token_secret.id
  secret_data = var.github_token
}

# 3. Repositório Dataform
resource "google_dataform_repository" "martech_repo" {
  provider = google-beta
  name     = "toolkit-martech-engine"
  region   = var.region

  git_remote_settings {
    url                                = var.github_repo_url
    default_branch                     = var.flavor
    authentication_token_secret_version = google_secret_manager_secret_version.github_token_version.id
  }

  workspace_compilation_overrides {
    default_database = var.project_id
  }
}

# 4. IAM: Permissões para a Service Account do Dataform
data "google_project" "project" {}

resource "google_project_iam_member" "dataform_bq_admin" {
  project = var.project_id
  role    = "roles/bigquery.admin"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

resource "google_secret_manager_secret_iam_member" "dataform_secret_accessor" {
  secret_id = google_secret_manager_secret.github_token_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-dataform.iam.gserviceaccount.com"
}

# 5. Configuração de Release e Workflow (Automação de Execução)
resource "google_dataform_repository_release_config" "daily_release" {
  provider   = google-beta
  repository = google_dataform_repository.martech_repo.name
  name       = "daily-release"
  git_commitish = var.flavor
  schedule      = "0 0 * * *"
}

resource "google_dataform_repository_workflow_config" "full_workflow" {
  provider       = google-beta
  repository     = google_dataform_repository.martech_repo.name
  name           = "full-execution"
  release_config = google_dataform_repository_release_config.daily_release.id
  
  invocation_config {
    transitive_dependencies_included = true
  }
}