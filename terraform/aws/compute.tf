###########################################
################ Key Pair #################
###########################################

resource "tls_private_key" "key_pair" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = var.global_prefix
  public_key = tls_private_key.key_pair.public_key_openssh
}

resource "local_file" "private_key" {
  content  = tls_private_key.key_pair.private_key_pem
  filename = "cert.pem"
}

resource "null_resource" "private_key_permissions" {
  depends_on = [local_file.private_key]

  provisioner "local-exec" {
    command     = "chmod 600 cert.pem"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

###########################################
############## REST Proxy #################
###########################################

resource "aws_instance" "rest_proxy" {
  depends_on = [
    aws_subnet.private_subnet,
    aws_nat_gateway.default,
  ]

  count         = var.instance_count["rest_proxy"]
  ami           = var.ec2_ami
  instance_type = "t3.medium"
  key_name      = aws_key_pair.generated_key.key_name

  subnet_id              = element(aws_subnet.private_subnet.*.id, count.index)
  vpc_security_group_ids = [aws_security_group.rest_proxy[0].id]

  user_data = data.template_file.rest_proxy_bootstrap.rendered

  root_block_device {
    volume_type = "gp2"
    volume_size = 100
  }

  tags = {
    Name = "rest-proxy-${var.global_prefix}-${count.index}"
  }
}

###########################################
############# Kafka Connect ###############
###########################################

resource "aws_instance" "kafka_connect" {
  depends_on = [
    aws_subnet.private_subnet,
    aws_nat_gateway.default,
  ]

  count         = var.instance_count["kafka_connect"]
  ami           = var.ec2_ami
  instance_type = "t3.medium"
  key_name      = aws_key_pair.generated_key.key_name

  subnet_id              = element(aws_subnet.private_subnet.*.id, count.index)
  vpc_security_group_ids = [aws_security_group.kafka_connect[0].id]

  user_data = data.template_file.kafka_connect_bootstrap.rendered

  root_block_device {
    volume_type = "gp2"
    volume_size = 100
  }

  tags = {
    Name = "kafka-connect-${var.global_prefix}-${count.index}"
  }
}

###########################################
############## KSQL Server ################
###########################################

resource "aws_instance" "ksql_server" {
  depends_on = [
    aws_subnet.private_subnet,
    aws_nat_gateway.default,
  ]

  count         = var.instance_count["ksql_server"]
  ami           = var.ec2_ami
  instance_type = "t3.2xlarge"
  key_name      = aws_key_pair.generated_key.key_name

  subnet_id              = element(aws_subnet.private_subnet.*.id, count.index)
  vpc_security_group_ids = [aws_security_group.ksql_server[0].id]

  user_data = data.template_file.ksql_server_bootstrap.rendered

  root_block_device {
    volume_type = "gp2"
    volume_size = 300
  }

  tags = {
    Name = "ksql-server-${var.global_prefix}-${count.index}"
  }
}

###########################################
############ Control Center ###############
###########################################

resource "aws_instance" "control_center" {
  depends_on = [
    aws_instance.kafka_connect,
    aws_instance.ksql_server,
  ]

  count         = var.instance_count["control_center"]
  ami           = var.ec2_ami
  instance_type = "t3.2xlarge"
  key_name      = aws_key_pair.generated_key.key_name

  subnet_id              = element(aws_subnet.private_subnet.*.id, count.index)
  vpc_security_group_ids = [aws_security_group.control_center[0].id]

  user_data = data.template_file.control_center_bootstrap.rendered

  root_block_device {
    volume_type = "gp2"
    volume_size = 300
  }

  tags = {
    Name = "control-center-${var.global_prefix}-${count.index}"
  }
}

###########################################
############ Bastion Server ###############
###########################################

resource "aws_instance" "bastion_server" {
  depends_on = [
    aws_instance.rest_proxy,
    aws_instance.kafka_connect,
    aws_instance.ksql_server,
    aws_instance.control_center,
  ]

  count = var.instance_count["bastion_server"] >= 1 ? 1 : 0

  ami           = var.ec2_ami
  instance_type = "t2.micro"
  key_name      = aws_key_pair.generated_key.key_name

  subnet_id              = aws_subnet.bastion_server[0].id
  vpc_security_group_ids = [aws_security_group.bastion_server[0].id]

  user_data = data.template_file.bastion_server_bootstrap.rendered

  root_block_device {
    volume_type = "gp2"
    volume_size = 10
  }

  tags = {
    Name = "bastion-server-${var.global_prefix}"
  }
}

###########################################
############# REST Proxy LBR ##############
###########################################

resource "aws_alb_target_group" "rest_proxy_target_group" {
  count = var.instance_count["rest_proxy"] >= 1 ? 1 : 0

  name     = "rp-target-group-${var.global_prefix}"
  port     = "8082"
  protocol = "HTTP"
  vpc_id   = aws_vpc.default.id

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    path                = "/"
    port                = "8082"
  }
}

resource "aws_alb_target_group_attachment" "rest_proxy_attachment" {
  count = var.instance_count["rest_proxy"] >= 1 ? var.instance_count["rest_proxy"] : 0

  target_group_arn = aws_alb_target_group.rest_proxy_target_group[0].arn
  target_id        = element(aws_instance.rest_proxy.*.id, count.index)
  port             = 8082
}

resource "aws_alb" "rest_proxy" {
  depends_on = [aws_instance.rest_proxy]
  count      = var.instance_count["rest_proxy"] >= 1 ? 1 : 0

  name            = "rest-proxy-${var.global_prefix}"
  subnets         = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  security_groups = [aws_security_group.load_balancer.id]
  internal        = false

  tags = {
    Name = "rest-proxy-${var.global_prefix}"
  }
}

resource "aws_alb_listener" "rest_proxy_listener" {
  count = var.instance_count["rest_proxy"] >= 1 ? 1 : 0

  load_balancer_arn = aws_alb.rest_proxy[0].arn
  protocol          = "HTTP"
  port              = "80"

  default_action {
    target_group_arn = aws_alb_target_group.rest_proxy_target_group[0].arn
    type             = "forward"
  }
}

###########################################
########### Kafka Connect LBR #############
###########################################

resource "aws_alb_target_group" "kafka_connect_target_group" {
  count = var.instance_count["kafka_connect"] >= 1 ? 1 : 0

  name     = "kc-target-group-${var.global_prefix}"
  port     = "8083"
  protocol = "HTTP"
  vpc_id   = aws_vpc.default.id

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    path                = "/"
    port                = "8083"
  }
}

resource "aws_alb_target_group_attachment" "kafka_connect_attachment" {
  count = var.instance_count["kafka_connect"] >= 1 ? var.instance_count["kafka_connect"] : 0

  target_group_arn = aws_alb_target_group.kafka_connect_target_group[0].arn
  target_id        = element(aws_instance.kafka_connect.*.id, count.index)
  port             = 8083
}

resource "aws_alb" "kafka_connect" {
  depends_on = [aws_instance.kafka_connect]
  count      = var.instance_count["kafka_connect"] >= 1 ? 1 : 0

  name            = "kafka-connect-${var.global_prefix}"
  subnets         = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  security_groups = [aws_security_group.load_balancer.id]
  internal        = false

  tags = {
    Name = "kafka-connect-${var.global_prefix}"
  }
}

resource "aws_alb_listener" "kafka_connect_listener" {
  count = var.instance_count["kafka_connect"] >= 1 ? 1 : 0

  load_balancer_arn = aws_alb.kafka_connect[0].arn
  protocol          = "HTTP"
  port              = "80"

  default_action {
    target_group_arn = aws_alb_target_group.kafka_connect_target_group[0].arn
    type             = "forward"
  }
}

###########################################
############# KSQL Server LBR #############
###########################################

resource "aws_alb_target_group" "ksql_server_target_group" {
  count = var.instance_count["ksql_server"] >= 1 ? 1 : 0

  name     = "ks-target-group-${var.global_prefix}"
  port     = "8088"
  protocol = "HTTP"
  vpc_id   = aws_vpc.default.id

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    path                = "/info"
    port                = "8088"
  }
}

resource "aws_alb_target_group_attachment" "ksql_server_attachment" {
  count = var.instance_count["ksql_server"] >= 1 ? var.instance_count["ksql_server"] : 0

  target_group_arn = aws_alb_target_group.ksql_server_target_group[0].arn
  target_id        = element(aws_instance.ksql_server.*.id, count.index)
  port             = 8088
}

resource "aws_alb" "ksql_server" {
  depends_on = [aws_instance.ksql_server]
  count      = var.instance_count["ksql_server"] >= 1 ? 1 : 0

  name            = "ksql-server-${var.global_prefix}"
  subnets         = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  security_groups = [aws_security_group.load_balancer.id]
  internal        = false

  tags = {
    Name = "ksql-server-${var.global_prefix}"
  }
}

resource "aws_alb_listener" "ksql_server_listener" {
  count = var.instance_count["ksql_server"] >= 1 ? 1 : 0

  load_balancer_arn = aws_alb.ksql_server[0].arn
  protocol          = "HTTP"
  port              = "80"

  default_action {
    target_group_arn = aws_alb_target_group.ksql_server_target_group[0].arn
    type             = "forward"
  }
}

###########################################
########### Control Center LBR ############
###########################################

resource "aws_alb_target_group" "control_center_target_group" {
  count = var.instance_count["control_center"] >= 1 ? 1 : 0

  name     = "cc-target-group-${var.global_prefix}"
  port     = "9021"
  protocol = "HTTP"
  vpc_id   = aws_vpc.default.id

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 3
    interval            = 5
    path                = "/"
    port                = "9021"
  }
}

resource "aws_alb_target_group_attachment" "control_center_attachment" {
  count = var.instance_count["control_center"] >= 1 ? var.instance_count["control_center"] : 0

  target_group_arn = aws_alb_target_group.control_center_target_group[0].arn
  target_id        = element(aws_instance.control_center.*.id, count.index)
  port             = 9021
}

resource "aws_alb" "control_center" {
  depends_on = [aws_instance.control_center]
  count      = var.instance_count["control_center"] >= 1 ? 1 : 0

  name            = "control-center-${var.global_prefix}"
  subnets         = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
  security_groups = [aws_security_group.load_balancer.id]
  internal        = false

  tags = {
    Name = "control-center-${var.global_prefix}"
  }
}

resource "aws_alb_listener" "control_center_listener" {
  count = var.instance_count["control_center"] >= 1 ? 1 : 0

  load_balancer_arn = aws_alb.control_center[0].arn
  protocol          = "HTTP"
  port              = "80"

  default_action {
    target_group_arn = aws_alb_target_group.control_center_target_group[0].arn
    type             = "forward"
  }
}

