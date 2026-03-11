# 1. DADOS DO PROJETO
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

# 3. FORÇAR CRIAÇÃO DA IDENTIDADE DO DATAFORM (Mata o erro 400)
resource "google_project_service_identity" "dataform_sa" {
  provider = google-beta
  project  = var.project_id
  service  = "dataform.googleapis.com"
  depends_on = [google_project_service.required_apis]
}

# 4. SEGURANÇA (SECRET MANAGER)
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

# 5. PAUSA TÉCNICA (30s para propagação de APIs e Identidades)
resource "time_sleep" "wait_for_propagation" {
  depends_on = [
    google_project_service_identity.dataform_sa,
    google_project_service.required_apis
  ]
  create_duration = "30s"
}

# 6. PERMISSÕES DE IAM (DATAFORM E WORKFLOW)
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

# Dá ao Workflow (Compute SA) poder para rodar o Dataform
resource "google_project_iam_member" "workflow_dataform_editor" {
  project = var.project_id
  role    = "roles/dataform.editor"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# 7. REPOSITÓRIO DATAFORM
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

  depends_on = [time_sleep.wait_for_propagation, google_secret_manager_secret_iam_member.dataform_accessor]
}

# 8. RELEASE CONFIG (Compilação manual referenciada pelo Workflow)
resource "google_dataform_repository_release_config" "manual_release" {
  provider   = google-beta
  project    = var.project_id
  repository = google_dataform_repository.martech_repo.name
  name       = "manual-release"
  git_commitish = var.flavor
}

# 9. SETUP DO WORKSPACE (Criação e Pull via API)
resource "null_resource" "dataform_setup" {
  provisioner "local-exec" {
    command = <<EOT
      TOKEN=$(gcloud auth print-access-token)
      REPO_PATH="projects/${var.project_id}/locations/us-east1/repositories/${google_dataform_repository.martech_repo.name}"
      
      echo "Aguardando estabilização final do repositório..."
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

# 10. ORQUESTRADOR (CLOUD WORKFLOWS)
resource "google_workflows_workflow" "orchestrator" {
  name            = "martech-orchestrator"
  region          = "us-east1"
  project         = var.project_id
  description     = "Executa o pipeline via Toolkit v7"
  service_account = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"

  source_contents = file("${path.module}/main_orchestrator.yaml")

  depends_on = [google_dataform_repository.martech_repo, google_project_iam_member.workflow_dataform_editor]
}

# 11. AGENDAMENTO (CLOUD SCHEDULER)
resource "google_cloud_scheduler_job" "daily_trigger" {
  name             = "daily-martech-sync"
  description      = "Gatilho diário para o Workflow de Martech"
  schedule         = "0 6 * * *" # Todos os dias às 06h
  time_zone        = "America/Sao_Paulo"
  region           = "us-east1"
  project          = var.project_id

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.orchestrator.id}/executions"
    body        = base64encode("{}")

    oauth_token {
      service_account_email = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
    }
  }

  depends_on = [google_workflows_workflow.orchestrator]
}

# Permissão para o Scheduler chamar o Workflow
resource "google_project_iam_member" "scheduler_workflow_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}