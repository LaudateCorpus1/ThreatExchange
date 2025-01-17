# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved

terraform {
  required_providers {
    aws = "~> 3.0"
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# PDQ Hasher
resource "aws_sqs_queue" "hashes_queue" {
  name_prefix                = "${var.prefix}-pdq-hashes"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 1209600
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQHashesQueue"
    }
  )
}

resource "aws_lambda_function" "pdq_hasher" {
  function_name = "${var.prefix}_pdq_hasher"
  package_type  = "Image"
  role          = aws_iam_role.pdq_hasher.arn
  image_uri     = var.lambda_docker_info.uri
  image_config {
    command = [var.lambda_docker_info.commands.hasher]
  }
  timeout     = 300
  memory_size = 512
  environment {
    variables = {
      PDQ_HASHES_QUEUE_URL = aws_sqs_queue.hashes_queue.id
      DYNAMODB_TABLE       = var.datastore.name
      MEASURE_PERFORMANCE  = var.measure_performance ? "True" : "False"
      METRICS_NAMESPACE    = var.metrics_namespace
      IMAGE_FOLDER_KEY     = var.images_input.image_folder_key
    }
  }
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQHasherFunction"
    }
  )
}

resource "aws_cloudwatch_log_group" "pdq_hasher" {
  name              = "/aws/lambda/${aws_lambda_function.pdq_hasher.function_name}"
  retention_in_days = var.log_retention_in_days
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQHasherLambdaLogGroup"
    }
  )
}

resource "aws_iam_role" "pdq_hasher" {
  name_prefix        = "${var.prefix}_pdq_hasher"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQHasherLambdaRole"
    }
  )
}

data "aws_iam_policy_document" "pdq_hasher" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
    resources = [var.images_input.input_queue]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.hashes_queue.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = var.images_input.resource_list
  }
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [var.datastore.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["${aws_cloudwatch_log_group.pdq_hasher.arn}:*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "pdq_hasher" {
  name_prefix = "${var.prefix}_pdq_hasher_role_policy"
  description = "Permissions for PDQ Hasher Lambda"
  policy      = data.aws_iam_policy_document.pdq_hasher.json
}

resource "aws_iam_role_policy_attachment" "pdq_hasher" {
  role       = aws_iam_role.pdq_hasher.name
  policy_arn = aws_iam_policy.pdq_hasher.arn
}

resource "aws_lambda_event_source_mapping" "pdq_hasher" {
  event_source_arn                   = var.images_input.input_queue
  function_name                      = aws_lambda_function.pdq_hasher.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 10
}

# PDQ Matcher

resource "aws_lambda_function" "pdq_matcher" {
  function_name = "${var.prefix}_pdq_matcher"
  package_type  = "Image"
  role          = aws_iam_role.pdq_matcher.arn
  image_uri     = var.lambda_docker_info.uri
  image_config {
    command = [var.lambda_docker_info.commands.matcher]
  }
  timeout     = 300
  memory_size = 512
  environment {
    variables = {
      PDQ_MATCHES_TOPIC_ARN = var.matches_sns_topic_arn
      INDEXES_BUCKET_NAME   = var.index_data_storage.bucket_name
      DYNAMODB_TABLE        = var.datastore.name
      MEASURE_PERFORMANCE   = var.measure_performance ? "True" : "False"
      METRICS_NAMESPACE     = var.metrics_namespace
      HMA_CONFIG_TABLE      = var.config_table.name
    }
  }
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQMatcherFunction"
    }
  )
}

resource "aws_cloudwatch_log_group" "pdq_matcher" {
  name              = "/aws/lambda/${aws_lambda_function.pdq_matcher.function_name}"
  retention_in_days = var.log_retention_in_days
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQMatcherLambdaLogGroup"
    }
  )
}

resource "aws_iam_role" "pdq_matcher" {
  name_prefix        = "${var.prefix}_pdq_matcher"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags = merge(
    var.additional_tags,
    {
      Name = "PDQMatcherLambdaRole"
    }
  )
}

data "aws_iam_policy_document" "pdq_matcher" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes", "sqs:ReceiveMessage", "sqs:DeleteMessage"]
    resources = [aws_sqs_queue.hashes_queue.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [var.matches_sns_topic_arn]
  }
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.index_data_storage.bucket_name}/${var.index_data_storage.index_folder_key}*"
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [var.datastore.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["${aws_cloudwatch_log_group.pdq_matcher.arn}:*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
    resources = [var.config_table.arn]
  }
}

resource "aws_iam_policy" "pdq_matcher" {
  name_prefix = "${var.prefix}_pdq_hasher_role_policy"
  description = "Permissions for PDQ Matcher Lambda"
  policy      = data.aws_iam_policy_document.pdq_matcher.json
}

resource "aws_iam_role_policy_attachment" "pdq_matcher" {
  role       = aws_iam_role.pdq_matcher.name
  policy_arn = aws_iam_policy.pdq_matcher.arn
}

resource "aws_lambda_event_source_mapping" "pdq_matcher" {
  event_source_arn                   = aws_sqs_queue.hashes_queue.arn
  function_name                      = aws_lambda_function.pdq_matcher.arn
  batch_size                         = var.queue_batch_size
  maximum_batching_window_in_seconds = var.queue_window_in_seconds
}
