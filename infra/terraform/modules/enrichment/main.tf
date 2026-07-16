data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    DataClass   = "confidential-receipt-metadata"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = local.tags
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.name}-public-${count.index + 1}" })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 4)
  tags              = merge(local.tags, { Name = "${local.name}-private-${count.index + 1}" })
}

resource "aws_eip" "nat" {
  count  = var.nat_gateway_count
  domain = "vpc"
  tags   = local.tags
}

resource "aws_nat_gateway" "main" {
  count         = var.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
  tags          = local.tags
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = local.tags
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[min(count.index, var.nat_gateway_count - 1)].id
  }
  tags = local.tags
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_kms_key" "data" {
  description             = "${local.name} application and database encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = local.tags
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_ecr_repository" "service" {
  name                 = "${local.name}-enrichment"
  image_tag_mutability = "IMMUTABLE"
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.data.arn
  }
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "service" {
  repository = aws_ecr_repository.service.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "retain latest 30 immutable images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_sqs_queue" "dead_letter" {
  name                      = "${local.name}-receipts-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.data.arn
  tags                      = local.tags
}

resource "aws_sqs_queue" "receipts" {
  name                       = "${local.name}-receipts"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20
  kms_master_key_id          = aws_kms_key.data.arn
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = 5
  })
  tags = local.tags
}

resource "aws_sqs_queue" "credit" {
  name                      = "${local.name}-credit-disabled"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.data.arn
  tags                      = merge(local.tags, { ProviderStatus = "disabled" })
}

resource "random_password" "database" {
  length  = 40
  special = true
}

resource "random_id" "final_snapshot" {
  byte_length = 4
}

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "PostgreSQL from enrichment tasks only"
  vpc_id      = aws_vpc.main.id
  tags        = local.tags
}

resource "aws_db_instance" "postgres" {
  identifier                      = "${local.name}-postgres"
  engine                          = "postgres"
  engine_version                  = "17.5"
  instance_class                  = "db.t4g.micro"
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.data.arn
  db_name                         = "challanse"
  username                        = "challanse_app"
  password                        = random_password.database.result
  multi_az                        = var.multi_az
  backup_retention_period         = 7
  copy_tags_to_snapshot           = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${local.name}-final-${random_id.final_snapshot.hex}"
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.database.id]
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.data.arn
  auto_minor_version_upgrade      = true
  publicly_accessible             = false
  apply_immediately               = false
  tags                            = local.tags
}

resource "aws_secretsmanager_secret" "runtime" {
  name                    = "${local.name}/enrichment-runtime"
  kms_key_id              = aws_kms_key.data.arn
  recovery_window_in_days = 30
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "runtime_database" {
  secret_id = aws_secretsmanager_secret.runtime.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://${aws_db_instance.postgres.username}:${urlencode(random_password.database.result)}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${aws_db_instance.postgres.db_name}?sslmode=require"
  })
  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${local.name}/enrichment"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.data.arn
  tags              = local.tags
}

resource "aws_iam_role" "task_execution" {
  name = "${local.name}-task-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
      Resource = [aws_secretsmanager_secret.runtime.arn, aws_kms_key.data.arn]
    }]
  })
}

resource "aws_iam_role" "task" {
  name = "${local.name}-task"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "task" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:SendMessage"]
        Resource = [aws_sqs_queue.receipts.arn, aws_sqs_queue.dead_letter.arn, aws_sqs_queue.credit.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["textract:DetectDocumentText", "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments", "xray:PutTelemetryRecords", "cloudwatch:PutMetricData",
          "logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "HTTPS origin behind Cloudflare Access"
  vpc_id      = aws_vpc.main.id
  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group" "service" {
  name        = "${local.name}-service"
  description = "Enrichment API and worker"
  vpc_id      = aws_vpc.main.id
  tags        = local.tags
}

resource "aws_security_group_rule" "service_from_alb" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.service.id
  source_security_group_id = aws_security_group.alb.id
  description              = "FastAPI traffic from the ALB only"
}

resource "aws_security_group_rule" "alb_to_service" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.service.id
  description              = "FastAPI targets only"
}

#trivy:ignore:AVD-AWS-0104 HTTPS egress is required for Cloudflare callbacks and explicitly enabled provider APIs.
resource "aws_security_group_rule" "service_https_egress" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.service.id
  description       = "HTTPS only for Cloudflare callbacks and enabled provider APIs"
}

resource "aws_security_group_rule" "service_dns_udp_egress" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.service.id
  description       = "VPC DNS resolution"
}

resource "aws_security_group_rule" "service_dns_tcp_egress" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.service.id
  description       = "VPC DNS fallback"
}

resource "aws_security_group_rule" "service_database_egress" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.service.id
  source_security_group_id = aws_security_group.database.id
  description              = "PostgreSQL only"
}

resource "aws_security_group_rule" "database_from_service" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.database.id
  source_security_group_id = aws_security_group.service.id
}

#trivy:ignore:AVD-AWS-0053 The ALB is intentionally reachable through a Cloudflare Access-protected origin; the API also requires service-token and HMAC validation.
resource "aws_lb" "api" {
  name                       = substr("${local.name}-api", 0, 32)
  internal                   = false
  load_balancer_type         = "application"
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  tags                       = local.tags
}

resource "aws_lb_target_group" "api" {
  name        = substr("${local.name}-api", 0, 32)
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }
  tags = local.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

locals {
  common_environment = [
    { name = "ENVIRONMENT", value = var.environment },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "EVENT_QUEUE_PROVIDER", value = "sqs" },
    { name = "RECEIPT_QUEUE_URL", value = aws_sqs_queue.receipts.url },
    { name = "CREDIT_QUEUE_URL", value = aws_sqs_queue.credit.url },
    { name = "KMS_KEY_ARN", value = aws_kms_key.data.arn },
    { name = "OCR_PROVIDER", value = "disabled" },
    { name = "GST_PROVIDER", value = "disabled" },
    { name = "NOTIFICATION_PROVIDER", value = "disabled" },
    { name = "CREDIT_PROVIDER", value = "disabled" },
    { name = "SLACK_PROVIDER", value = "disabled" },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://127.0.0.1:4318/v1/traces" }
  ]
  runtime_secrets = [
    for key in [
      "DATABASE_URL", "CLOUDFLARE_API_URL", "EDGE_TO_ENRICHMENT_HMAC_KEY_ID", "EDGE_TO_ENRICHMENT_HMAC_KEY",
      "EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY_ID", "EDGE_TO_ENRICHMENT_NEXT_HMAC_KEY",
      "ENRICHMENT_TO_EDGE_HMAC_KEY_ID", "ENRICHMENT_TO_EDGE_HMAC_KEY",
      "ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY_ID", "ENRICHMENT_TO_EDGE_NEXT_HMAC_KEY", "CLOUDFLARE_ACCESS_CLIENT_ID",
      "CLOUDFLARE_ACCESS_CLIENT_SECRET"
    ] : { name = key, valueFrom = "${aws_secretsmanager_secret.runtime.arn}:${key}::" }
  ]
  adot_container = {
    name      = "aws-otel-collector"
    image     = var.adot_collector_image
    essential = true
    command   = ["--config=env:AOT_CONFIG_CONTENT"]
    environment = [{
      name  = "AOT_CONFIG_CONTENT"
      value = <<-YAML
        receivers:
          otlp:
            protocols:
              http:
                endpoint: 0.0.0.0:4318
        processors:
          batch: {}
        exporters:
          awsxray: {}
          awsemf:
            namespace: ChallanSe/${var.environment}
        service:
          pipelines:
            traces:
              receivers: [otlp]
              processors: [batch]
              exporters: [awsxray]
            metrics:
              receivers: [otlp]
              processors: [batch]
              exporters: [awsemf]
      YAML
    }]
    portMappings     = [{ containerPort = 4318, hostPort = 4318, protocol = "tcp" }]
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.service.name, awslogs-region = var.aws_region, awslogs-stream-prefix = "adot" } }
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name             = "api"
    image            = var.container_image
    command          = ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers"]
    essential        = true
    environment      = local.common_environment
    secrets          = local.runtime_secrets
    portMappings     = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    healthCheck      = { command = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/health')\""], interval = 30, timeout = 5, retries = 3, startPeriod = 20 }
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.service.name, awslogs-region = var.aws_region, awslogs-stream-prefix = "api" } }
  }, local.adot_container])
  tags = local.tags
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions = jsonencode([{
    name             = "worker"
    image            = var.container_image
    command          = ["python", "-m", "app.tasks"]
    essential        = true
    environment      = local.common_environment
    secrets          = local.runtime_secrets
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.service.name, awslogs-region = var.aws_region, awslogs-stream-prefix = "worker" } }
  }, local.adot_container])
  tags = local.tags
}

resource "aws_ecs_service" "api" {
  name                               = "api"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.services_enabled ? var.api_desired_count : 0
  launch_type                        = "FARGATE"
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.https]
  tags       = local.tags
}

resource "aws_ecs_service" "worker" {
  name            = "worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.services_enabled ? var.worker_desired_count : 0
  launch_type     = "FARGATE"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }
  tags = local.tags
}

locals {
  scheduled_jobs = {
    digest    = { expression = "rate(4 hours)", command = "digest" }
    telemetry = { expression = "cron(30 20 * * ? *)", command = "telemetry" }
    retention = { expression = "cron(15 21 * * ? *)", command = "retention" }
  }
}

resource "aws_iam_role" "scheduled_jobs" {
  name = "${local.name}-scheduled-jobs"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "scheduled_jobs" {
  role = aws_iam_role.scheduled_jobs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecs:RunTask"], Resource = [aws_ecs_task_definition.worker.arn] },
      { Effect = "Allow", Action = ["iam:PassRole"], Resource = [aws_iam_role.task.arn, aws_iam_role.task_execution.arn] }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "scheduled_jobs" {
  for_each            = local.scheduled_jobs
  name                = "${local.name}-${each.key}"
  schedule_expression = each.value.expression
  state               = var.services_enabled ? "ENABLED" : "DISABLED"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "scheduled_jobs" {
  for_each = local.scheduled_jobs
  rule     = aws_cloudwatch_event_rule.scheduled_jobs[each.key].name
  arn      = aws_ecs_cluster.main.arn
  role_arn = aws_iam_role.scheduled_jobs.arn
  input = jsonencode({
    containerOverrides = [{ name = "worker", command = ["python", "-m", "app.jobs", each.value.command] }]
  })
  ecs_target {
    launch_type         = "FARGATE"
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.worker.arn
    network_configuration {
      subnets          = aws_subnet.private[*].id
      security_groups  = [aws_security_group.service.id]
      assign_public_ip = false
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name = "${local.name}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${var.environment}" }
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "github_deploy" {
  role = aws_iam_role.github_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy",
        "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:AttachRolePolicy",
        "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies", "iam:PassRole"
      ]
      Resource = "arn:aws:iam::*:role/${var.project}-${var.environment}-*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_deploy_power_user" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${local.name}-dlq-visible"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.dead_letter.name }
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${local.name}-queue-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 900
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.receipts.name }
  tags                = local.tags
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 70
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
