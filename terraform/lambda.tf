# Schedule locals
locals {
  schedules = {
    weekday_start = {
      cron      = "cron(0 19 ? * 2-5 *)" # 12:00 PM MST Mon–Thu
      action    = "start"
      rule_name = "start-crafty-weekday"
      target_id = "StartCraftyWeekday"
    }
    weekday_stop = {
      cron      = "cron(0 6 ? * 2-5 *)" # 11:00 PM MST Mon–Thu (next day UTC)
      action    = "stop"
      rule_name = "stop-crafty-weekday"
      target_id = "StopCraftyWeekday"
    }
    weekend_start = {
      cron      = "cron(0 19 ? * 6,7,1 *)" # 12:00 PM MST Fri–Sun
      action    = "start"
      rule_name = "start-crafty-weekend"
      target_id = "StartCraftyWeekend"
    }
    weekend_stop = {
      cron      = "cron(59 6 ? * 6,7,1 *)" # 11:59 PM MST Fri–Sun (next day UTC)
      action    = "stop"
      rule_name = "stop-crafty-weekend"
      target_id = "StopCraftyWeekend"
    }
  }
}

resource "aws_lambda_function" "start_crafty" {
  count            = var.enable_lambda ? 1 : 0
  function_name    = "start-crafty-daily"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "dist/handler.handler"
  runtime          = "nodejs22.x"
  filename         = "${path.module}/../lambda/handler.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/handler.zip")

  environment {
    variables = {
      INSTANCE_ID = aws_instance.crafty.id
      REGION      = var.aws_region
      ACTION      = "start"
    }
  }
}

resource "aws_lambda_function" "stop_crafty" {
  count            = var.enable_lambda ? 1 : 0
  function_name    = "stop-crafty-daily"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "dist/handler.handler"
  runtime          = "nodejs22.x"
  filename         = "${path.module}/../lambda/handler.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/handler.zip")

  environment {
    variables = {
      INSTANCE_ID = aws_instance.crafty.id
      REGION      = var.aws_region
      ACTION      = "stop"
    }
  }
}

# IAM Role and Policy
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_ec2_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "lambda_ec2_control" {
  name = "LambdaEC2ControlPolicy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances"
        ],
        Resource = aws_instance.crafty.arn
      }
    ]
  })
}

# Attach execution role policy to the Lambda role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_ec2_control.arn
}

# Event Rules, Targets, and Permissions
resource "aws_cloudwatch_event_rule" "schedules" {
  for_each            = var.enable_lambda ? local.schedules : {}
  name                = each.value.rule_name
  schedule_expression = each.value.cron
}

resource "aws_cloudwatch_event_target" "schedules" {
  for_each  = var.enable_lambda ? local.schedules : {}
  rule      = aws_cloudwatch_event_rule.schedules[each.key].name
  target_id = each.value.target_id
  arn       = each.value.action == "start" ? aws_lambda_function.start_crafty[0].arn : aws_lambda_function.stop_crafty[0].arn
}

resource "aws_lambda_permission" "schedules" {
  for_each      = var.enable_lambda ? local.schedules : {}
  statement_id  = "AllowInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.action == "start" ? aws_lambda_function.start_crafty[0].function_name : aws_lambda_function.stop_crafty[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedules[each.key].arn
}
