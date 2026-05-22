# =============================================================================
# RAIS PoC AWS Cleanup Script (v2)
# =============================================================================
# 태그 Project=rais-poc 가 붙은 모든 리소스를 의존성 순서대로 삭제합니다.
# 운영 계정(908835050057)에서는 실행되지 않도록 가드되어 있습니다.
#
# v2 추가 처리 (v1 누락분):
#   - Cloud Map (Service Discovery) namespace + services + instances
#   - CloudWatch Alarms (rais-poc-*)
#   - SNS Topics + Subscriptions (rais-poc-alerts)
#   - Secrets Manager (force delete without recovery)
#   - VPC Flow Logs (resource)
#   - Route53 Private Zone (rais-poc.local) — 명시적 잔여 정리
#   - Route53 Public Zone (raispoc.store) + ACM cert (옵션 -KeepDomain)
#   - Task definition family에 worker 추가
#   - Log group 매칭 확대 (/aws/ecs/containerinsights/, /aws/vpc/rais-poc-flowlogs)
#
# 사용법:
#   .\aws-cleanup.ps1                       # 전체 삭제 (도메인 포함)
#   .\aws-cleanup.ps1 -KeepDomain           # raispoc.store 도메인/ACM 보존
#   .\aws-cleanup.ps1 -DryRun               # 무엇이 삭제될지만 출력
#   .\aws-cleanup.ps1 -Profile freetier     # 프로파일 지정
# =============================================================================

[CmdletBinding()]
param(
    [string]$Profile = "",
    [string]$Region = "ap-northeast-2",
    [string]$TagKey = "Project",
    [string]$TagValue = "rais-poc",
    [string]$BlockedAccount = "908835050057",  # 운영 계정 (실행 차단)
    [switch]$KeepDomain,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"
$ProfileArg = if ($Profile) { @("--profile", $Profile) } else { @() }
$RegionArg = @("--region", $Region)

function Write-Step($msg)   { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-Info($msg)   { Write-Host "  [INFO] $msg" -ForegroundColor Gray }
function Write-Ok($msg)     { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host "  [ERROR] $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 0. 계정 가드
# -----------------------------------------------------------------------------
Write-Step "Account guard"
$identity = & aws @ProfileArg sts get-caller-identity --output json 2>&1 | ConvertFrom-Json
if (-not $identity -or -not $identity.Account) {
    Write-Err "AWS CLI 인증 실패. Profile/Credentials 확인 필요."
    exit 1
}
Write-Info "Account: $($identity.Account)"
Write-Info "User:    $($identity.Arn)"
Write-Info "Region:  $Region"

if ($identity.Account -eq $BlockedAccount) {
    Write-Err "BLOCKED: 이 계정($BlockedAccount)은 운영 계정으로 등록되어 cleanup 실행 차단됩니다."
    Write-Err "프리티어 계정으로 프로파일을 전환한 뒤 다시 실행하세요."
    exit 1
}

Write-Host ""
Write-Host "다음 계정의 ${TagKey}=${TagValue} 태그 리소스가 모두 삭제됩니다:" -ForegroundColor Yellow
Write-Host "  Account     : $($identity.Account)" -ForegroundColor Yellow
Write-Host "  Region      : $Region" -ForegroundColor Yellow
Write-Host "  KeepDomain  : $KeepDomain (raispoc.store + ACM 보존 여부)" -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "  Mode        : DRY-RUN (실제 삭제 안 함)" -ForegroundColor Yellow
}
Write-Host ""
$confirm = Read-Host "정말 진행하려면 'DELETE' 를 입력하세요"
if ($confirm -ne "DELETE") {
    Write-Warn "취소됨."
    exit 0
}

$Tag = "${TagKey}=${TagValue}"
$TagFilter = "Name=tag:${TagKey},Values=${TagValue}"

# -----------------------------------------------------------------------------
# 1. ECS Service / Cluster
# -----------------------------------------------------------------------------
Write-Step "ECS: services + cluster"
$clusters = & aws @ProfileArg @RegionArg ecs list-clusters --output json 2>$null | ConvertFrom-Json
foreach ($clusterArn in $clusters.clusterArns) {
    $clusterName = ($clusterArn -split "/")[-1]
    if ($clusterName -notmatch $TagValue) { continue }

    Write-Info "Cluster: $clusterName"
    $services = & aws @ProfileArg @RegionArg ecs list-services --cluster $clusterName --output json 2>$null | ConvertFrom-Json
    foreach ($svcArn in $services.serviceArns) {
        $svcName = ($svcArn -split "/")[-1]
        Write-Info "  Scaling down service: $svcName"
        if (-not $DryRun) {
            & aws @ProfileArg @RegionArg ecs update-service --cluster $clusterName --service $svcName --desired-count 0 --output json | Out-Null
            Start-Sleep -Seconds 5
            & aws @ProfileArg @RegionArg ecs delete-service --cluster $clusterName --service $svcName --force --output json | Out-Null
        }
    }

    # Capacity Provider 분리
    Write-Info "  Detaching capacity providers"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg ecs put-cluster-capacity-providers --cluster $clusterName --capacity-providers '[]' --default-capacity-provider-strategy '[]' --output json 2>$null | Out-Null
    }

    # ASG 삭제
    $cps = & aws @ProfileArg @RegionArg ecs describe-capacity-providers --output json 2>$null | ConvertFrom-Json
    foreach ($cp in $cps.capacityProviders) {
        if ($cp.name -match $TagValue -or $cp.name -match $clusterName) {
            $asgArn = $cp.autoScalingGroupProvider.autoScalingGroupArn
            if ($asgArn) {
                $asgName = ($asgArn -split "/")[-1]
                Write-Info "  Deleting ASG: $asgName"
                if (-not $DryRun) {
                    & aws @ProfileArg @RegionArg autoscaling delete-auto-scaling-group --auto-scaling-group-name $asgName --force-delete --output json 2>$null | Out-Null
                }
            }
            Write-Info "  Deleting capacity provider: $($cp.name)"
            if (-not $DryRun) {
                & aws @ProfileArg @RegionArg ecs delete-capacity-provider --capacity-provider $cp.name --output json 2>$null | Out-Null
            }
        }
    }

    Write-Info "  Deleting cluster"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg ecs delete-cluster --cluster $clusterName --output json 2>$null | Out-Null
    }
    Write-Ok "Cluster $clusterName scheduled for deletion"
}

# Task Definitions deregister (worker 추가 — v2)
$tdFamilies = @("rais-poc-backend", "rais-poc-worker", "rais-poc-python")
foreach ($family in $tdFamilies) {
    $tds = & aws @ProfileArg @RegionArg ecs list-task-definitions --family-prefix $family --status ACTIVE --output json 2>$null | ConvertFrom-Json
    foreach ($td in $tds.taskDefinitionArns) {
        Write-Info "  Deregistering task def: $td"
        if (-not $DryRun) {
            & aws @ProfileArg @RegionArg ecs deregister-task-definition --task-definition $td --output json 2>$null | Out-Null
        }
    }
}

# -----------------------------------------------------------------------------
# 2. Cloud Map (Service Discovery) — v2 신규
# -----------------------------------------------------------------------------
Write-Step "Cloud Map: services + namespace"
$nsList = & aws @ProfileArg @RegionArg servicediscovery list-namespaces --output json 2>$null | ConvertFrom-Json
foreach ($ns in $nsList.Namespaces) {
    if ($ns.Name -notmatch $TagValue) { continue }
    Write-Info "Namespace: $($ns.Name) ($($ns.Id))"

    # namespace 내 서비스 + instances 정리
    $svcs = & aws @ProfileArg @RegionArg servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=$($ns.Id),Condition=EQ" --output json 2>$null | ConvertFrom-Json
    foreach ($svc in $svcs.Services) {
        Write-Info "  Service: $($svc.Name) ($($svc.Id))"
        # 등록된 instances 먼저 deregister
        $insts = & aws @ProfileArg @RegionArg servicediscovery list-instances --service-id $svc.Id --output json 2>$null | ConvertFrom-Json
        foreach ($i in $insts.Instances) {
            Write-Info "    Deregistering instance: $($i.Id)"
            if (-not $DryRun) {
                & aws @ProfileArg @RegionArg servicediscovery deregister-instance --service-id $svc.Id --instance-id $i.Id --output json 2>$null | Out-Null
            }
        }
        if ($insts.Instances.Count -gt 0 -and -not $DryRun) { Start-Sleep -Seconds 10 }
        Write-Info "    Deleting service"
        if (-not $DryRun) {
            & aws @ProfileArg @RegionArg servicediscovery delete-service --id $svc.Id --output json 2>$null | Out-Null
        }
    }

    Write-Info "  Deleting namespace (Route53 private zone 자동 정리)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg servicediscovery delete-namespace --id $ns.Id --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 3. ALB + Target Group
# -----------------------------------------------------------------------------
Write-Step "ALB + Target Group"
$albs = & aws @ProfileArg @RegionArg elbv2 describe-load-balancers --output json 2>$null | ConvertFrom-Json
foreach ($alb in $albs.LoadBalancers) {
    $tagsResp = & aws @ProfileArg @RegionArg elbv2 describe-tags --resource-arns $alb.LoadBalancerArn --output json 2>$null | ConvertFrom-Json
    $hasTag = $tagsResp.TagDescriptions[0].Tags | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
    if (-not $hasTag) { continue }

    Write-Info "Deleting ALB: $($alb.LoadBalancerName)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg elbv2 delete-load-balancer --load-balancer-arn $alb.LoadBalancerArn --output json | Out-Null
    }
    Write-Ok "ALB deletion requested"
}
Start-Sleep -Seconds 15

$tgs = & aws @ProfileArg @RegionArg elbv2 describe-target-groups --output json 2>$null | ConvertFrom-Json
foreach ($tg in $tgs.TargetGroups) {
    $tagsResp = & aws @ProfileArg @RegionArg elbv2 describe-tags --resource-arns $tg.TargetGroupArn --output json 2>$null | ConvertFrom-Json
    $hasTag = $tagsResp.TagDescriptions[0].Tags | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
    if (-not $hasTag) { continue }

    Write-Info "Deleting target group: $($tg.TargetGroupName)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg elbv2 delete-target-group --target-group-arn $tg.TargetGroupArn --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 4. CloudFront (disable -> wait -> delete)
# -----------------------------------------------------------------------------
Write-Step "CloudFront distributions"
$cfList = & aws @ProfileArg cloudfront list-distributions --output json 2>$null | ConvertFrom-Json
$cfTargets = @()
if ($cfList.DistributionList.Items) {
    foreach ($d in $cfList.DistributionList.Items) {
        $tagsResp = & aws @ProfileArg cloudfront list-tags-for-resource --resource $d.ARN --output json 2>$null | ConvertFrom-Json
        $hasTag = $tagsResp.Tags.Items | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
        if ($hasTag) { $cfTargets += $d }
    }
}

# Phase A: Disable
foreach ($d in $cfTargets) {
    Write-Info "Disabling CloudFront: $($d.Id)"
    if ($DryRun) { continue }

    $cfg = & aws @ProfileArg cloudfront get-distribution-config --id $d.Id --output json 2>$null | ConvertFrom-Json
    if (-not $cfg.DistributionConfig.Enabled) {
        Write-Info "  Already disabled"
        continue
    }
    $cfg.DistributionConfig.Enabled = $false
    $cfg.DistributionConfig | ConvertTo-Json -Depth 50 | Out-File -Encoding utf8 -FilePath "$env:TEMP\cfg-$($d.Id).json"
    & aws @ProfileArg cloudfront update-distribution --id $d.Id --distribution-config "file://$env:TEMP\cfg-$($d.Id).json" --if-match $cfg.ETag --output json 2>$null | Out-Null
}

# Phase B: Wait
foreach ($d in $cfTargets) {
    if ($DryRun) { continue }
    Write-Info "Waiting for $($d.Id) to finish disabling (최대 20분)"
    $maxWait = 1200; $waited = 0
    while ($waited -lt $maxWait) {
        $status = & aws @ProfileArg cloudfront get-distribution --id $d.Id --query "Distribution.Status" --output text 2>$null
        if ($status -eq "Deployed") { Write-Ok "  Deployed (ready to delete)"; break }
        Start-Sleep -Seconds 30; $waited += 30
        Write-Host "." -NoNewline
    }
    Write-Host ""
}

# Phase C: Delete
foreach ($d in $cfTargets) {
    if ($DryRun) { continue }
    $etag = & aws @ProfileArg cloudfront get-distribution-config --id $d.Id --query "ETag" --output text 2>$null
    Write-Info "Deleting CloudFront: $($d.Id)"
    & aws @ProfileArg cloudfront delete-distribution --id $d.Id --if-match $etag --output json 2>$null | Out-Null
}

# OAC 삭제
$oacs = & aws @ProfileArg cloudfront list-origin-access-controls --output json 2>$null | ConvertFrom-Json
if ($oacs.OriginAccessControlList.Items) {
    foreach ($oac in $oacs.OriginAccessControlList.Items) {
        if ($oac.Name -match $TagValue) {
            $etag = & aws @ProfileArg cloudfront get-origin-access-control --id $oac.Id --query "ETag" --output text 2>$null
            Write-Info "Deleting OAC: $($oac.Name)"
            if (-not $DryRun) {
                & aws @ProfileArg cloudfront delete-origin-access-control --id $oac.Id --if-match $etag --output json 2>$null | Out-Null
            }
        }
    }
}

# -----------------------------------------------------------------------------
# 5. S3 buckets
# -----------------------------------------------------------------------------
Write-Step "S3 buckets"
$buckets = & aws @ProfileArg s3api list-buckets --query "Buckets[].Name" --output json 2>$null | ConvertFrom-Json
foreach ($b in $buckets) {
    $tagsJson = & aws @ProfileArg s3api get-bucket-tagging --bucket $b --output json 2>$null
    if (-not $tagsJson) { continue }
    $tagsObj = $tagsJson | ConvertFrom-Json
    $hasTag = $tagsObj.TagSet | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
    if (-not $hasTag) { continue }

    Write-Info "Emptying + deleting bucket: $b"
    if (-not $DryRun) {
        & aws @ProfileArg s3 rm "s3://$b" --recursive --output text 2>$null | Out-Null
        & aws @ProfileArg s3api delete-bucket --bucket $b --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 6. CloudWatch Alarms — v2 신규
# -----------------------------------------------------------------------------
Write-Step "CloudWatch Alarms"
$alarms = & aws @ProfileArg @RegionArg cloudwatch describe-alarms --query "MetricAlarms[?starts_with(AlarmName,'rais-poc')].AlarmName" --output json 2>$null | ConvertFrom-Json
if ($alarms.Count -gt 0) {
    Write-Info "Deleting alarms: $($alarms -join ', ')"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg cloudwatch delete-alarms --alarm-names $alarms --output json 2>$null | Out-Null
    }
}
# ASG 자동 생성 알람 (TargetTracking-Infra-ECS-Cluster-rais-poc-...)
$asgAlarms = & aws @ProfileArg @RegionArg cloudwatch describe-alarms --query "MetricAlarms[?contains(AlarmName,'rais-poc-ecs-cluster')].AlarmName" --output json 2>$null | ConvertFrom-Json
if ($asgAlarms.Count -gt 0) {
    Write-Info "Deleting ASG-managed alarms: $($asgAlarms.Count) 개"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg cloudwatch delete-alarms --alarm-names $asgAlarms --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 7. SNS Topics + Subscriptions — v2 신규
# -----------------------------------------------------------------------------
Write-Step "SNS Topics"
$topics = & aws @ProfileArg @RegionArg sns list-topics --output json 2>$null | ConvertFrom-Json
foreach ($t in $topics.Topics) {
    if ($t.TopicArn -notmatch "rais-poc") { continue }
    Write-Info "Topic: $($t.TopicArn)"
    $subs = & aws @ProfileArg @RegionArg sns list-subscriptions-by-topic --topic-arn $t.TopicArn --output json 2>$null | ConvertFrom-Json
    foreach ($s in $subs.Subscriptions) {
        if ($s.SubscriptionArn -ne "PendingConfirmation") {
            Write-Info "  Unsubscribing: $($s.Endpoint)"
            if (-not $DryRun) {
                & aws @ProfileArg @RegionArg sns unsubscribe --subscription-arn $s.SubscriptionArn --output json 2>$null | Out-Null
            }
        }
    }
    Write-Info "  Deleting topic"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg sns delete-topic --topic-arn $t.TopicArn --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 8. Secrets Manager — v2 신규
# -----------------------------------------------------------------------------
Write-Step "Secrets Manager"
$secrets = & aws @ProfileArg @RegionArg secretsmanager list-secrets --query "SecretList[?starts_with(Name,'rais-poc')]" --output json 2>$null | ConvertFrom-Json
foreach ($s in $secrets) {
    Write-Info "Deleting secret (force, no recovery): $($s.Name)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg secretsmanager delete-secret --secret-id $s.ARN --force-delete-without-recovery --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 9. RDS
# -----------------------------------------------------------------------------
Write-Step "RDS instances"
$dbs = & aws @ProfileArg @RegionArg rds describe-db-instances --output json 2>$null | ConvertFrom-Json
foreach ($db in $dbs.DBInstances) {
    $tagsResp = & aws @ProfileArg @RegionArg rds list-tags-for-resource --resource-name $db.DBInstanceArn --output json 2>$null | ConvertFrom-Json
    $hasTag = $tagsResp.TagList | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
    if (-not $hasTag) { continue }

    Write-Info "Deleting RDS: $($db.DBInstanceIdentifier) (skip final snapshot)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg rds modify-db-instance --db-instance-identifier $db.DBInstanceIdentifier --no-deletion-protection --apply-immediately --output json 2>$null | Out-Null
        Start-Sleep -Seconds 5
        & aws @ProfileArg @RegionArg rds delete-db-instance --db-instance-identifier $db.DBInstanceIdentifier --skip-final-snapshot --delete-automated-backups --output json 2>$null | Out-Null
    }
}

$dbsgs = & aws @ProfileArg @RegionArg rds describe-db-subnet-groups --output json 2>$null | ConvertFrom-Json

# -----------------------------------------------------------------------------
# 10. ElastiCache
# -----------------------------------------------------------------------------
Write-Step "ElastiCache"
$ecs = & aws @ProfileArg @RegionArg elasticache describe-cache-clusters --output json 2>$null | ConvertFrom-Json
foreach ($c in $ecs.CacheClusters) {
    $tagsResp = & aws @ProfileArg @RegionArg elasticache list-tags-for-resource --resource-name $c.ARN --output json 2>$null | ConvertFrom-Json
    $hasTag = $tagsResp.TagList | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
    if (-not $hasTag) { continue }
    Write-Info "Deleting cache cluster: $($c.CacheClusterId)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg elasticache delete-cache-cluster --cache-cluster-id $c.CacheClusterId --output json 2>$null | Out-Null
    }
}

$rgs = & aws @ProfileArg @RegionArg elasticache describe-replication-groups --output json 2>$null | ConvertFrom-Json
foreach ($rg in $rgs.ReplicationGroups) {
    $tagsResp = & aws @ProfileArg @RegionArg elasticache list-tags-for-resource --resource-name $rg.ARN --output json 2>$null | ConvertFrom-Json
    $hasTag = $tagsResp.TagList | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }
    if (-not $hasTag) { continue }
    Write-Info "Deleting replication group: $($rg.ReplicationGroupId)"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg elasticache delete-replication-group --replication-group-id $rg.ReplicationGroupId --no-retain-primary-cluster --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 11. EC2 instances (잔여 — ASG 외)
# -----------------------------------------------------------------------------
Write-Step "EC2 instances"
$instances = & aws @ProfileArg @RegionArg ec2 describe-instances --filters $TagFilter "Name=instance-state-name,Values=running,stopped,stopping,pending" --query "Reservations[].Instances[].InstanceId" --output json 2>$null | ConvertFrom-Json
if ($instances.Count -gt 0) {
    Write-Info "Terminating instances: $($instances -join ', ')"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg ec2 terminate-instances --instance-ids $instances --output json 2>$null | Out-Null
    }
}

# Bastion은 태그 없을 수 있어서 이름 매칭으로 fallback
$bastionInsts = & aws @ProfileArg @RegionArg ec2 describe-instances --filters "Name=tag:Name,Values=rais-poc-bastion,rais-poc-*" "Name=instance-state-name,Values=running,stopped,stopping,pending" --query "Reservations[].Instances[].InstanceId" --output json 2>$null | ConvertFrom-Json
if ($bastionInsts.Count -gt 0) {
    Write-Info "Terminating name-matched instances: $($bastionInsts -join ', ')"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg ec2 terminate-instances --instance-ids $bastionInsts --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 12. RDS / ElastiCache / EC2 삭제 완료 대기
# -----------------------------------------------------------------------------
Write-Step "Waiting for RDS / ElastiCache / EC2 deletion to complete"
if (-not $DryRun) {
    # RDS waiter
    $rdsTargets = $dbs.DBInstances | Where-Object {
        $tagsResp = & aws @ProfileArg @RegionArg rds list-tags-for-resource --resource-name $_.DBInstanceArn --output json 2>$null | ConvertFrom-Json
        ($tagsResp.TagList | Where-Object { $_.Key -eq $TagKey -and $_.Value -eq $TagValue }).Count -gt 0
    }
    foreach ($db in $rdsTargets) {
        Write-Info "Waiting for RDS $($db.DBInstanceIdentifier)..."
        $maxWait = 900; $waited = 0
        while ($waited -lt $maxWait) {
            $exists = & aws @ProfileArg @RegionArg rds describe-db-instances --db-instance-identifier $db.DBInstanceIdentifier --query "DBInstances[0].DBInstanceStatus" --output text 2>$null
            if (-not $exists -or $exists -match "DBInstanceNotFound" -or $LASTEXITCODE -ne 0) { Write-Ok "  Deleted"; break }
            Start-Sleep -Seconds 30; $waited += 30
            Write-Host "." -NoNewline
        }
        Write-Host ""
    }

    # DB Subnet group
    foreach ($sg in $dbsgs.DBSubnetGroups) {
        if ($sg.DBSubnetGroupName -match $TagValue) {
            Write-Info "Deleting DB subnet group: $($sg.DBSubnetGroupName)"
            & aws @ProfileArg @RegionArg rds delete-db-subnet-group --db-subnet-group-name $sg.DBSubnetGroupName --output json 2>$null | Out-Null
        }
    }

    # ElastiCache subnet group
    $ecsgs = & aws @ProfileArg @RegionArg elasticache describe-cache-subnet-groups --output json 2>$null | ConvertFrom-Json
    foreach ($sg in $ecsgs.CacheSubnetGroups) {
        if ($sg.CacheSubnetGroupName -match $TagValue) {
            Write-Info "Deleting cache subnet group: $($sg.CacheSubnetGroupName)"
            & aws @ProfileArg @RegionArg elasticache delete-cache-subnet-group --cache-subnet-group-name $sg.CacheSubnetGroupName --output json 2>$null | Out-Null
        }
    }
}

# -----------------------------------------------------------------------------
# 13. VPC Flow Logs (resource) — v2 신규
# -----------------------------------------------------------------------------
Write-Step "VPC Flow Logs"
$vpcsForFlowLogs = & aws @ProfileArg @RegionArg ec2 describe-vpcs --filters $TagFilter --query "Vpcs[].VpcId" --output json 2>$null | ConvertFrom-Json
foreach ($vpcId in $vpcsForFlowLogs) {
    $flowLogs = & aws @ProfileArg @RegionArg ec2 describe-flow-logs --filter "Name=resource-id,Values=$vpcId" --query "FlowLogs[].FlowLogId" --output json 2>$null | ConvertFrom-Json
    if ($flowLogs.Count -gt 0) {
        Write-Info "Deleting flow logs for $vpcId : $($flowLogs -join ', ')"
        if (-not $DryRun) {
            & aws @ProfileArg @RegionArg ec2 delete-flow-logs --flow-log-ids $flowLogs --output json 2>$null | Out-Null
        }
    }
}

# -----------------------------------------------------------------------------
# 14. NAT Gateway -> EIP
# -----------------------------------------------------------------------------
Write-Step "NAT Gateway + EIP"
$nats = & aws @ProfileArg @RegionArg ec2 describe-nat-gateways --filter $TagFilter "Name=state,Values=available,pending" --query "NatGateways[].NatGatewayId" --output json 2>$null | ConvertFrom-Json
foreach ($natId in $nats) {
    Write-Info "Deleting NAT GW: $natId"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg ec2 delete-nat-gateway --nat-gateway-id $natId --output json 2>$null | Out-Null
    }
}
if ($nats.Count -gt 0 -and -not $DryRun) {
    Write-Info "Waiting for NAT GW deletion (~3 min)"
    Start-Sleep -Seconds 180
}

$eips = & aws @ProfileArg @RegionArg ec2 describe-addresses --filters $TagFilter --query "Addresses[].AllocationId" --output json 2>$null | ConvertFrom-Json
foreach ($alloc in $eips) {
    Write-Info "Releasing EIP: $alloc"
    if (-not $DryRun) {
        & aws @ProfileArg @RegionArg ec2 release-address --allocation-id $alloc --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 15. VPC + 부속
# -----------------------------------------------------------------------------
Write-Step "VPC tear-down"
$vpcs = & aws @ProfileArg @RegionArg ec2 describe-vpcs --filters $TagFilter --query "Vpcs[].VpcId" --output json 2>$null | ConvertFrom-Json
foreach ($vpcId in $vpcs) {
    Write-Info "VPC: $vpcId"

    # Network Interfaces (잔여 ENI — task ENI 등)
    $enis = & aws @ProfileArg @RegionArg ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpcId" --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" --output json 2>$null | ConvertFrom-Json
    foreach ($eni in $enis) {
        Write-Info "  Deleting ENI: $eni"
        if (-not $DryRun) { & aws @ProfileArg @RegionArg ec2 delete-network-interface --network-interface-id $eni --output json 2>$null | Out-Null }
    }

    # VPC Endpoints
    $vpces = & aws @ProfileArg @RegionArg ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpcId" --query "VpcEndpoints[].VpcEndpointId" --output json 2>$null | ConvertFrom-Json
    if ($vpces.Count -gt 0) {
        Write-Info "  Deleting VPC endpoints: $($vpces -join ', ')"
        if (-not $DryRun) { & aws @ProfileArg @RegionArg ec2 delete-vpc-endpoints --vpc-endpoint-ids $vpces --output json 2>$null | Out-Null }
    }

    # IGW
    $igws = & aws @ProfileArg @RegionArg ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --query "InternetGateways[].InternetGatewayId" --output json 2>$null | ConvertFrom-Json
    foreach ($igw in $igws) {
        Write-Info "  Detaching + deleting IGW: $igw"
        if (-not $DryRun) {
            & aws @ProfileArg @RegionArg ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpcId --output json 2>$null | Out-Null
            & aws @ProfileArg @RegionArg ec2 delete-internet-gateway --internet-gateway-id $igw --output json 2>$null | Out-Null
        }
    }

    # Subnets
    $subnets = & aws @ProfileArg @RegionArg ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --query "Subnets[].SubnetId" --output json 2>$null | ConvertFrom-Json
    foreach ($sn in $subnets) {
        Write-Info "  Deleting subnet: $sn"
        if (-not $DryRun) { & aws @ProfileArg @RegionArg ec2 delete-subnet --subnet-id $sn --output json 2>$null | Out-Null }
    }

    # Route Tables (메인 제외 — PowerShell 측 필터링으로 backtick escape 회피)
    $allRts = & aws @ProfileArg @RegionArg ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" --output json 2>$null | ConvertFrom-Json
    foreach ($rtObj in $allRts.RouteTables) {
        $isMain = $rtObj.Associations | Where-Object { $_.Main }
        if ($isMain) { continue }
        Write-Info "  Deleting route table: $($rtObj.RouteTableId)"
        if (-not $DryRun) { & aws @ProfileArg @RegionArg ec2 delete-route-table --route-table-id $rtObj.RouteTableId --output json 2>$null | Out-Null }
    }

    # Security Groups (default 제외)
    $sgs = & aws @ProfileArg @RegionArg ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" --query "SecurityGroups[?GroupName!='default'].GroupId" --output json 2>$null | ConvertFrom-Json
    # 룰 먼저 비우기 (cross-reference 깨기)
    foreach ($sg in $sgs) {
        $ingressJson = & aws @ProfileArg @RegionArg ec2 describe-security-groups --group-ids $sg --query "SecurityGroups[0].IpPermissions" --output json 2>$null
        if ($ingressJson -and $ingressJson.Trim() -ne "[]") {
            if (-not $DryRun) {
                $ingressJson | Out-File -Encoding utf8 -FilePath "$env:TEMP\sg-ingress-$sg.json"
                & aws @ProfileArg @RegionArg ec2 revoke-security-group-ingress --group-id $sg --ip-permissions "file://$env:TEMP\sg-ingress-$sg.json" --output json 2>$null | Out-Null
            }
        }
    }
    foreach ($sg in $sgs) {
        Write-Info "  Deleting SG: $sg"
        if (-not $DryRun) { & aws @ProfileArg @RegionArg ec2 delete-security-group --group-id $sg --output json 2>$null | Out-Null }
    }

    Write-Info "  Deleting VPC: $vpcId"
    if (-not $DryRun) { & aws @ProfileArg @RegionArg ec2 delete-vpc --vpc-id $vpcId --output json 2>$null | Out-Null }
}

# -----------------------------------------------------------------------------
# 16. Route 53 Private Zone (잔여 정리) — v2 신규
# -----------------------------------------------------------------------------
Write-Step "Route53 Private Zone (rais-poc.local) — 잔여 확인"
$zones = & aws @ProfileArg route53 list-hosted-zones --output json 2>$null | ConvertFrom-Json
foreach ($z in $zones.HostedZones) {
    if ($z.Name -ne "rais-poc.local.") { continue }
    if (-not $z.Config.PrivateZone) { continue }
    Write-Info "Private zone 잔여 발견: $($z.Id)"
    $records = & aws @ProfileArg route53 list-resource-record-sets --hosted-zone-id $z.Id --output json 2>$null | ConvertFrom-Json
    foreach ($r in $records.ResourceRecordSets) {
        if ($r.Type -in @("NS", "SOA")) { continue }
        Write-Info "  Deleting record: $($r.Name) $($r.Type)"
        if (-not $DryRun) {
            $batch = @{ Changes = @(@{ Action = "DELETE"; ResourceRecordSet = $r }) } | ConvertTo-Json -Depth 50
            $batch | Out-File -Encoding utf8 -FilePath "$env:TEMP\r53-del-$($z.Id -replace '/','-').json"
            & aws @ProfileArg route53 change-resource-record-sets --hosted-zone-id $z.Id --change-batch "file://$env:TEMP\r53-del-$($z.Id -replace '/','-').json" --output json 2>$null | Out-Null
        }
    }
    Write-Info "  Deleting hosted zone: $($z.Id)"
    if (-not $DryRun) {
        & aws @ProfileArg route53 delete-hosted-zone --id $z.Id --output json 2>$null | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 17. Route 53 Public Zone (raispoc.store) + ACM — 옵션 (-KeepDomain) — v2 신규
# -----------------------------------------------------------------------------
if ($KeepDomain) {
    Write-Step "Route53 Public Zone + ACM (보존 — -KeepDomain)"
    Write-Info "raispoc.store 도메인 보존. 다음 학습에 재사용 가능."
} else {
    Write-Step "Route53 Public Zone (raispoc.store) + ACM"
    foreach ($z in $zones.HostedZones) {
        if ($z.Name -ne "raispoc.store.") { continue }
        if ($z.Config.PrivateZone) { continue }
        Write-Info "Public zone: $($z.Id)"
        $records = & aws @ProfileArg route53 list-resource-record-sets --hosted-zone-id $z.Id --output json 2>$null | ConvertFrom-Json
        foreach ($r in $records.ResourceRecordSets) {
            if ($r.Type -in @("NS", "SOA")) { continue }
            Write-Info "  Deleting record: $($r.Name) $($r.Type)"
            if (-not $DryRun) {
                $batch = @{ Changes = @(@{ Action = "DELETE"; ResourceRecordSet = $r }) } | ConvertTo-Json -Depth 50
                $batch | Out-File -Encoding utf8 -FilePath "$env:TEMP\r53-delp-$($z.Id -replace '/','-').json"
                & aws @ProfileArg route53 change-resource-record-sets --hosted-zone-id $z.Id --change-batch "file://$env:TEMP\r53-delp-$($z.Id -replace '/','-').json" --output json 2>$null | Out-Null
            }
        }
        Write-Info "  Deleting public hosted zone: $($z.Id)"
        if (-not $DryRun) {
            & aws @ProfileArg route53 delete-hosted-zone --id $z.Id --output json 2>$null | Out-Null
        }
    }

    # ACM us-east-1 (CloudFront용 cert)
    $certsUs = & aws @ProfileArg --region us-east-1 acm list-certificates --query "CertificateSummaryList[?DomainName=='raispoc.store' || ends_with(DomainName,'.raispoc.store')].CertificateArn" --output json 2>$null | ConvertFrom-Json
    foreach ($cArn in $certsUs) {
        Write-Info "  Deleting ACM (us-east-1): $cArn"
        if (-not $DryRun) {
            & aws @ProfileArg --region us-east-1 acm delete-certificate --certificate-arn $cArn --output json 2>$null | Out-Null
        }
    }
    # ACM ap-northeast-2 (혹시 있으면)
    $certsAp = & aws @ProfileArg @RegionArg acm list-certificates --query "CertificateSummaryList[?DomainName=='raispoc.store' || ends_with(DomainName,'.raispoc.store')].CertificateArn" --output json 2>$null | ConvertFrom-Json
    foreach ($cArn in $certsAp) {
        Write-Info "  Deleting ACM ($Region): $cArn"
        if (-not $DryRun) {
            & aws @ProfileArg @RegionArg acm delete-certificate --certificate-arn $cArn --output json 2>$null | Out-Null
        }
    }
}

# -----------------------------------------------------------------------------
# 18. IAM Roles
# -----------------------------------------------------------------------------
Write-Step "IAM Roles"
$roleNames = @(
    "rais-poc-ecs-ec2-instance-role",
    "rais-poc-ecsTaskExecutionRole",
    "rais-poc-ssm-bastion-role"
)
foreach ($roleName in $roleNames) {
    $exists = & aws @ProfileArg iam get-role --role-name $roleName --output json 2>$null
    if ($LASTEXITCODE -ne 0) { continue }

    # Instance profile detach
    $ips = & aws @ProfileArg iam list-instance-profiles-for-role --role-name $roleName --query "InstanceProfiles[].InstanceProfileName" --output json 2>$null | ConvertFrom-Json
    foreach ($ip in $ips) {
        Write-Info "  Removing role from instance profile: $ip"
        if (-not $DryRun) {
            & aws @ProfileArg iam remove-role-from-instance-profile --instance-profile-name $ip --role-name $roleName --output json 2>$null | Out-Null
            & aws @ProfileArg iam delete-instance-profile --instance-profile-name $ip --output json 2>$null | Out-Null
        }
    }

    # Managed policy detach
    $attached = & aws @ProfileArg iam list-attached-role-policies --role-name $roleName --query "AttachedPolicies[].PolicyArn" --output json 2>$null | ConvertFrom-Json
    foreach ($p in $attached) {
        Write-Info "  Detaching policy: $p"
        if (-not $DryRun) { & aws @ProfileArg iam detach-role-policy --role-name $roleName --policy-arn $p --output json 2>$null | Out-Null }
    }

    # Inline policy delete
    $inline = & aws @ProfileArg iam list-role-policies --role-name $roleName --query "PolicyNames" --output json 2>$null | ConvertFrom-Json
    foreach ($p in $inline) {
        if (-not $DryRun) { & aws @ProfileArg iam delete-role-policy --role-name $roleName --policy-name $p --output json 2>$null | Out-Null }
    }

    Write-Info "Deleting role: $roleName"
    if (-not $DryRun) { & aws @ProfileArg iam delete-role --role-name $roleName --output json 2>$null | Out-Null }
}

# -----------------------------------------------------------------------------
# 19. CloudWatch Log Groups (Container Insights / Flow Logs / ECS task 로그 포함)
# -----------------------------------------------------------------------------
Write-Step "CloudWatch Log Groups"
$lgs = & aws @ProfileArg @RegionArg logs describe-log-groups --output json 2>$null | ConvertFrom-Json
foreach ($lg in $lgs.logGroups) {
    $name = $lg.logGroupName
    $isTarget = $false
    if ($name -match $TagValue) { $isTarget = $true }
    if ($name -match "rais-poc") { $isTarget = $true }
    if ($name -eq "/aws/ecs/containerinsights/rais-poc-ecs-cluster/performance") { $isTarget = $true }
    if ($name -eq "/aws/vpc/rais-poc-flowlogs") { $isTarget = $true }
    if (-not $isTarget) { continue }

    Write-Info "Deleting log group: $name"
    if (-not $DryRun) { & aws @ProfileArg @RegionArg logs delete-log-group --log-group-name $name --output json 2>$null | Out-Null }
}

# -----------------------------------------------------------------------------
# 20. ECR Repositories
# -----------------------------------------------------------------------------
Write-Step "ECR Repositories"
$repos = & aws @ProfileArg @RegionArg ecr describe-repositories --output json 2>$null | ConvertFrom-Json
foreach ($r in $repos.repositories) {
    if ($r.repositoryName -match "rais-poc" -or $r.repositoryName -match $TagValue -or $r.repositoryName -match "^awsstudy/") {
        Write-Info "Deleting ECR repo (force): $($r.repositoryName)"
        if (-not $DryRun) { & aws @ProfileArg @RegionArg ecr delete-repository --repository-name $r.repositoryName --force --output json 2>$null | Out-Null }
    }
}

# -----------------------------------------------------------------------------
# 21. 최종 검증
# -----------------------------------------------------------------------------
Write-Step "Final verification"
$leftover = & aws @ProfileArg @RegionArg resourcegroupstaggingapi get-resources --tag-filters "Key=$TagKey,Values=$TagValue" --query "ResourceTagMappingList[].ResourceARN" --output json 2>$null | ConvertFrom-Json
if ($leftover.Count -eq 0) {
    Write-Ok "모든 $TagKey=$TagValue 리소스가 정리되었습니다."
} else {
    Write-Warn "남은 리소스 ($($leftover.Count)개):"
    $leftover | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Warn "위 리소스는 수동으로 확인/삭제 필요. (CloudFront 삭제 진행 중일 수 있음 — 30분 후 다시 실행)"
}

Write-Host ""
Write-Host "=== Cleanup complete ===" -ForegroundColor Green
if ($DryRun) { Write-Host "(DRY-RUN 모드였습니다 — 실제 삭제는 일어나지 않음)" -ForegroundColor Yellow }
if ($KeepDomain) { Write-Host "(raispoc.store 도메인 + ACM 보존됨 — 다음 학습 재사용 가능)" -ForegroundColor Yellow }
Write-Host "내일 Cost Explorer에서 일 비용이 \$0.01 미만인지 확인하세요." -ForegroundColor Gray
