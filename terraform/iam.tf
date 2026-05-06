# IAM user dedicado ao bootstrap da instância Lightsail.
# Lightsail Instance NÃO suporta IAM Instance Role nativo (diferente de EC2),
# então precisamos de access key estática gravada via cloud-init em /etc/cpt/aws_credentials.
# Policy mínima: ler SSM /cpt/prod/* + decrypt da KMS aws/ssm.

resource "aws_iam_user" "bootstrap" {
  name = "${local.project}-instance-bootstrap"
  path = "/service/"
}

resource "aws_iam_user_policy" "ssm_read" {
  name = "${local.project}-ssm-read"
  user = aws_iam_user.bootstrap.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadCptProdSsmParams"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        # GetParametersByPath consulta o path EXATO como resource (parameter/cpt/prod),
        # GetParameter consulta cada parametro individual (parameter/cpt/prod/foo).
        # Precisamos cobrir os dois casos.
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}",
          "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}/*",
        ]
      },
      {
        Sid      = "WriteLastBackupAt"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}/last_backup_at"
      },
      {
        Sid    = "DecryptSsmKms"
        Effect = "Allow"
        Action = ["kms:Decrypt"]
        # Alias ARN da managed CMK que SSM usa pra SecureString. IAM resolve
        # alias -> key em runtime. Usamos alias (em vez de data "aws_kms_key")
        # pra evitar chicken-and-egg: em conta fresca, alias/aws/ssm so existe
        # apos a primeira SecureString — data source falharia em `plan` antes
        # disso. Condition kms:ViaService trava o uso ao SSM.
        Resource = "arn:aws:kms:${var.aws_region}:${local.account_id}:alias/aws/ssm"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "BackupsBucketWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "bootstrap" {
  user = aws_iam_user.bootstrap.name

  # Para rotacionar: terraform apply -replace=aws_iam_access_key.bootstrap
}
