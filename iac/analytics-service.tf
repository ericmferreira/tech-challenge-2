terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

resource "aws_sqs_queue" "analytics_queue" {
  name = "analytics-queue"
}

resource "aws_dynamodb_table" "analytics_table" {
  name           = "ToggleMasterAnalytics"
  billing_mode   = "PROVISIONED"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }
}

output "sqs_queue_url" {
  value = aws_sqs_queue.analytics_queue.url
}