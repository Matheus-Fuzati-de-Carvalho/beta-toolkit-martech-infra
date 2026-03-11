# 1. PEGAR O NÚMERO DO PROJETO DINAMICAMENTE
data "google_project" "project" {
  project_id = var.project_id
}

# 2. ATIVAÇÃO DE APIS (Adicionada Cloud Resource Manager para evitar o erro 403)
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

# 3. FORÇAR CRIAÇÃO DA IDENTIDADE DO DATAFORM (O segredo para evitar o erro 400)
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

# 5. PERMISSÕES (IAM) - Garantindo que o Dataform e o Workflows possam trabalhar
resource "google_secret_manager_secret_iam_member" "dataform_accessor" {
  secret_id = google_secret_manager_secret.github_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project_service_identity.dataform_sa.email}"
}

resource "google_project_iam_member" "dataform_bq_admin" {
  project = var.project_id
  role    = "roles/bigquery.admin"
  member  = "serviceAccount:${google_project_service_identity.dataform_sa.email}"
}

# 6. REPOSITÓRIO DATAFORM (Ajustado para os nomes da V7)
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

# 7. CONFIGURAÇÃO DO WORKSPACE E PULL (Dinâmico com var.flavor)
resource "null_resource" "dataform_setup" {
  provisioner "local-exec" {
    command = <<EOT
      TOKEN=$(gcloud auth print-access-token)
      REPO_PATH="projects/${var.project_id}/locations/us-east1/repositories/${google_dataform_repository.martech_repo.name}"
      
      echo "Aguardando estabilização..."
      sleep 30

      echo "Criando Workspace: main-workspace..."
      curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        "https://dataform.googleapis.com/v1beta1/$REPO_PATH/workspaces?workspaceId=main-workspace" || echo "Workspace já existe."

      echo "Sincronizando arquivos da branch ${var.flavor}..."
      curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d '{"remoteBranch": "${var.flavor}"}' \
        "https://dataform.googleapis.com/v1beta1/$REPO_PATH/workspaces/main-workspace:fetchRemoteAndMerge"
EOT
  }

  depends_on = [google_dataform_repository.martech_repo]
}

# 8. ORQUESTRADOR (CLOUD WORKFLOWS)
resource "google_workflows_workflow" "orchestrator" {
  name            = "martech-orchestrator"
  region          = "us-east1"
  project         = var.project_id
  description     = "Executa o pipeline do Dataform via Toolkit v7"
  service_account = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"

  # Certifique-se que o arquivo main_orchestrator.yaml existe na mesma pasta
  source_contents = file("${path.module}/main_orchestrator.yaml")

  depends_on = [google_project_service.required_apis]
}

# 9. AGENDAMENTO (CLOUD SCHEDULER)
resource "google_cloud_scheduler_job" "daily_trigger" {
  name             = "daily-martech-sync"
  description      = "Gatilho diário para o Workflow"
  schedule         = "0 6 * * *"
  time_zone        = "America/Sao_Paulo"
  region           = "us-east1"
  project          = var.project_id
  attempt_deadline = "320s"

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