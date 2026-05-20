# =============================================================================
# awsStudy ECR Push Script
# =============================================================================
# 백엔드/프론트엔드 이미지를 빌드해서 ECR에 푸시합니다.
#
# 사용법:
#   .\ecr-push.ps1 -AccountId 123456789012 -Profile freetier
#   .\ecr-push.ps1 -AccountId 123456789012 -Profile freetier -Service backend
#
# 사전 준비:
#   1. AWS CLI 프로파일이 신규 프리티어 계정을 가리켜야 함
#   2. ECR 리포지토리 2개 생성 필요 (자동 생성도 시도함):
#      - awsstudy/backend
#      - awsstudy/frontend
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AccountId,

    [string]$Profile = "",

    [string]$Region = "ap-northeast-2",

    [ValidateSet("all", "backend", "frontend")]
    [string]$Service = "all",

    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
$ProfileArg = if ($Profile) { @("--profile", $Profile) } else { @() }

if (-not $Tag) { $Tag = (Get-Date -Format "yyyyMMdd-HHmm") }

$Registry = "$AccountId.dkr.ecr.$Region.amazonaws.com"

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  [ERROR] $msg" -ForegroundColor Red }

# 계정 확인
Write-Step "Verify AWS account"
$identity = & aws @ProfileArg sts get-caller-identity --output json | ConvertFrom-Json
if ($identity.Account -ne $AccountId) {
    Write-Err "CLI 인증 계정($($identity.Account))과 지정한 AccountId($AccountId)가 다릅니다."
    exit 1
}
Write-Ok "Account: $($identity.Account) / $($identity.Arn)"

# ECR 리포지토리 생성 (이미 있으면 무시)
Write-Step "Ensure ECR repositories exist"
foreach ($repo in @("awsstudy/backend", "awsstudy/frontend")) {
    & aws @ProfileArg --region $Region ecr describe-repositories --repository-names $repo 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Creating repository: $repo"
        & aws @ProfileArg --region $Region ecr create-repository --repository-name $repo `
            --image-scanning-configuration scanOnPush=true `
            --tags Key=Project,Value=rais-poc Key=Owner,Value=jw.hong | Out-Null
        Write-Ok "Created: $repo"
    } else {
        Write-Ok "Exists: $repo"
    }
}

# Docker 로그인
Write-Step "Docker login to ECR"
$password = & aws @ProfileArg --region $Region ecr get-login-password
$password | docker login --username AWS --password-stdin $Registry
if ($LASTEXITCODE -ne 0) { Write-Err "docker login failed"; exit 1 }
Write-Ok "Logged in to $Registry"

function Build-And-Push($name, $contextPath) {
    Write-Step "Build & push: $name (tag: $Tag)"
    $localImage = "awsstudy/${name}:${Tag}"
    $remoteImage = "$Registry/awsstudy/${name}:${Tag}"
    $remoteLatest = "$Registry/awsstudy/${name}:latest"

    docker build -t $localImage $contextPath
    if ($LASTEXITCODE -ne 0) { Write-Err "docker build failed: $name"; exit 1 }

    docker tag $localImage $remoteImage
    docker tag $localImage $remoteLatest

    docker push $remoteImage
    if ($LASTEXITCODE -ne 0) { Write-Err "docker push failed: $remoteImage"; exit 1 }
    docker push $remoteLatest
    if ($LASTEXITCODE -ne 0) { Write-Err "docker push failed: $remoteLatest"; exit 1 }

    Write-Ok "Pushed: $remoteImage"
    Write-Ok "Pushed: $remoteLatest"
}

if ($Service -eq "all" -or $Service -eq "backend") {
    Build-And-Push -name "backend" -contextPath ".\backend"
}
if ($Service -eq "all" -or $Service -eq "frontend") {
    Build-And-Push -name "frontend" -contextPath ".\frontend"
}

Write-Host ""
Write-Host "=== Push complete ===" -ForegroundColor Green
Write-Host "  Backend:  $Registry/awsstudy/backend:$Tag" -ForegroundColor Gray
Write-Host "  Frontend: $Registry/awsstudy/frontend:$Tag" -ForegroundColor Gray
Write-Host ""
Write-Host "다음 단계: ECS Task Definition을 위 이미지 URI로 업데이트한 뒤 service 재배포" -ForegroundColor Gray
