###############################################################################
# PoC environment — shared settings (us-south-3 + us-east-3)
# Both files are passed together by scripts/deploy.sh; keep them identical.
###############################################################################

env_type            = "poc"
dc                  = "3"
resource_group_name = "niraj-sandbox-nprd"

worker_flavor = "bxf.4x16"
worker_count  = 3

# Existing KMS root key (Kubernetes secret encryption only) — REQUIRED.
# Find it with: ibmcloud ks kms crk ls --instance-id 652971d5-d7cf-48d3-85cf-64d7477134be
# kms_root_key_id = "<root-key-id>"
