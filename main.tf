terraform {
  required_providers {
    time = {
      source = "hashicorp/time"
    }
  }
}
# 1. PEGAR O NÚMERO DO PROJETO DINAMICAMENTE
data "google_project" "project" {
  project_id = var.project_id
}

# 2. ATIVAÇÃO DE APIS
resource "google_project_service" "required_apis" {
  for_each = toset([
    "bigquery.googleapis.com",
    "dataform.googleapis.com",
    "workflows.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com"
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# 3. SEGURANÇA (SECRET MANAGER)
resource "google_secret_manager_secret" "github_token" {
  secret_id = "dataform-github-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "github_token_version" {
  secret      = google_secret_manager_secret.github_token.id
  secret_data = var.github_token
}

# 4. FORÇAR CRIAÇÃO DA IDENTIDADE (Evita o erro 400 da SA)
resource "google_project_service_identity" "dataform_sa" {
  provider = google-beta
  project  = var.project_id
  service  = "dataform.googleapis.com"
  depends_on = [google_project_service.required_apis]
}

# 5. PERMISSÕES (IAM) - Dataform acessa o Secret e o BQ
resource "google_secret_manager_secret_iam_member" "dataform_accessor" {
  secret_id = google_secret_manager_secret.github_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project_service_identity.dataform_sa.email}"
}

resource "google_project_iam_member" "dataform_bq" {
  project = var.project_id
  role    = "roles/bigquery.admin"
  member  = "serviceAccount:${google_project_service_identity.dataform_sa.email}"
}

# 6. REPOSITÓRIO DATAFORM
resource "google_dataform_repository" "martech_repo" {
  provider = google-beta
  project  = var.project_id
  name     = "toolkit-martech-engine"
  region   = "us-east1"

  git_remote_settings {
    url                                 = var.github_repo_url
    default_branch                      = var.flavor
    authentication_token_secret_version = google_secret_manager_secret_version.github_token_version.id
  }

  workspace_compilation_overrides {
    default_database = var.project_id
  }

  depends_on = [google_secret_manager_secret_iam_member.dataform_accessor]
}

# 7. RELEASE CONFIG (Necessário para o Workflow ler)
resource "google_dataform_repository_release_config" "manual_release" {
  provider   = google-beta
  project    = var.project_id
  repository = google_dataform_repository.martech_repo.name
  name       = "manual-release"
  git_commitish = var.flavor
}

# 8. CONFIGURAÇÃO DO WORKSPACE E PULL (Correção do Endpoint :pull)
resource "null_resource" "dataform_setup" {
  provisioner "local-exec" {
    command = <<EOT
      TOKEN=$(gcloud auth print-access-token)
      REPO_PATH="projects/${var.project_id}/locations/us-east1/repositories/${google_dataform_repository.martech_repo.name}"
      
      echo "Aguardando estabilização final..."
      sleep 40

      echo "Criando Workspace: main-workspace..."
      curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        "https://dataform.googleapis.com/v1beta1/$REPO_PATH/workspaces?workspaceId=main-workspace" || echo "Workspace já existe."

      echo "Sincronizando branch ${var.flavor} via Pull..."
      curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        "https://dataform.googleapis.com/v1beta1/$REPO_PATH/workspaces/main-workspace:pull"
EOT
  }
  depends_on = [google_dataform_repository.martech_repo]
}

# 9. PAUSA DE SEGURANÇA PARA IAM (Garante que a Service Account exista no backend)
resource "time_sleep" "wait_for_iam" {
  depends_on = [google_project_service.required_apis]
  create_duration = "30s"
}

# 10. ORQUESTRADOR (CLOUD WORKFLOWS)
resource "google_workflows_workflow" "orchestrator" {
  name            = "martech-orchestrator"
  region          = "us-east1"
  project         = var.project_id
  description     = "Executa o pipeline via Toolkit v7"
  service_account = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"

  source_contents = file("${path.module}/main_orchestrator.yaml")

  # Importante: Depender da pausa de segurança
  depends_on = [time_sleep.wait_for_iam, google_dataform_repository.martech_repo]
}