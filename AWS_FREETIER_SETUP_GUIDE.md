# RAIS 인프라 PoC 구축 가이드 (콘솔 클릭)

> 목표: 운영 다이어그램과 **동일한 구조**를, **사양은 최저**로 한 번 띄워보고 검증 후 cleanup 스크립트로 일괄 삭제
> 예상 비용: ~$0.16/h, 24시간 띄우면 약 $4
> 예산 한도: $10 (학습비)
> 앱 코드는 올리지 않음 — **인프라 골격만** 구축 (ECS는 nginx 더미 이미지)

---

## 0. 사전 준비 (필수, 5분)

### 0-1. 모든 리소스에 공통 태그 부여 약속
나중에 cleanup 스크립트가 이 태그로 리소스를 찾아 지웁니다. **모든** 단계에서 동일하게:

| Key | Value |
|---|---|
| `Project` | `rais-poc` |
| `Owner` | `jw.hong` |

> 콘솔에서 리소스 생성 화면 맨 아래 "Tags" 섹션에 항상 추가하세요.

### 0-2. AWS Budgets 알림 (가장 먼저!)
1. AWS 콘솔 → **Billing and Cost Management** → **Budgets**
2. **Create budget** → "Use a template (simplified)" → **Monthly cost budget**
3. Budget amount: **$10**, Email: 본인 이메일
4. 추가로 "Zero spend budget" 도 함께 만들면 첫 청구 발생 시 즉시 알림

### 0-3. 리전 확인
콘솔 우측 상단 **서울 (ap-northeast-2)** 선택 고정.

---

## 1. VPC + 네트워크 (15분)

### 1-1. VPC 생성 (한 번에)
**VPC 콘솔** → **Create VPC** → **VPC and more** (이게 핵심: 한 번에 다 만들어 줌)

| 필드 | 값 |
|---|---|
| Name auto-generate | `rais-poc` |
| IPv4 CIDR | `10.0.0.0/16` |
| Number of AZs | **2** |
| Number of public subnets | **2** |
| Number of private subnets | **2** |
| NAT gateways | **In 1 AZ** ← (운영은 1개. **None** 하면 더 저렴하지만 구조 동일성 위해 1개) |
| VPC endpoints | **None** (S3 endpoint 만들지 않음 — 단순화) |
| DNS hostnames | ✅ Enable |
| DNS resolution | ✅ Enable |
| Tags | `Project=rais-poc`, `Owner=jw.hong` |

→ **Create VPC** (3~5분 소요)

### 1-2. 생성된 것 확인
- VPC × 1: `rais-poc-vpc`
- Subnet × 4: public-2a, public-2c, private-2a, private-2c
- IGW × 1
- NAT Gateway × 1 (public-2a에)
- Route Table × 3 (public, private-2a용 NAT라우팅, private-2c용)
- EIP × 1 (NAT용)

⚠ **이 시점부터 NAT GW와 EIP가 시간당 과금 시작** ($0.064/h ≈ 시간당 86원)

---

## 2. Security Group (10분)

**VPC 콘솔 → Security Groups → Create security group**

### 2-1. `rais-poc-alb-sg` (ALB용)
- VPC: rais-poc-vpc
- Inbound: HTTP 80 from `0.0.0.0/0`, HTTPS 443 from `0.0.0.0/0`
- Outbound: All traffic
- Tags: 공통

### 2-2. `rais-poc-ecs-sg` (ECS 호스트용)
- Inbound: All TCP from `rais-poc-alb-sg` (ALB만 접근)
- Outbound: All traffic

### 2-3. `rais-poc-db-sg` (RDS용)
- Inbound: TCP 5432 from `rais-poc-ecs-sg`
- Outbound: All traffic (불필요하지만 기본값)

### 2-4. `rais-poc-redis-sg` (ElastiCache용)
- Inbound: TCP 6379 from `rais-poc-ecs-sg`
- Outbound: All traffic

### 2-5. `rais-poc-bastion-sg` (Bastion용)
- Inbound: **없음** (SSM 사용)
- Outbound: All traffic

### 2-6. DB/Redis SG 추가 룰 (Bastion 접근용)
- `rais-poc-db-sg`에 inbound 5432 from `rais-poc-bastion-sg` 추가
- `rais-poc-redis-sg`에 inbound 6379 from `rais-poc-bastion-sg` 추가

---

## 3. IAM Role 3개 (10분)

> 운영의 role 이름을 그대로 사용. 정책은 **AWS 관리형 정책 표준값** 사용 (운영 정책 조회 불가).

### 3-1. `rais-poc-ecs-ec2-instance-role` (ECS 호스트용)
**IAM 콘솔 → Roles → Create role**
- Trusted entity: **AWS service** → **EC2**
- Permissions: `AmazonEC2ContainerServiceforEC2Role` (관리형)
- Name: `rais-poc-ecs-ec2-instance-role`
- Tags: 공통

> 생성 후 **Instance profile**이 자동 생성됩니다 (동일 이름).

### 3-2. `rais-poc-ecsTaskExecutionRole` (Task Execution용)
- Trusted entity: **AWS service** → **Elastic Container Service** → **EC2 Container Service Task**
- Permissions: `AmazonECSTaskExecutionRolePolicy` (관리형)
- Name: `rais-poc-ecsTaskExecutionRole`

### 3-3. `rais-poc-ssm-bastion-role` (Bastion EC2용)
- Trusted entity: **AWS service** → **EC2**
- Permissions: `AmazonSSMManagedInstanceCore` (관리형)
- Name: `rais-poc-ssm-bastion-role`

---

## 4. RDS PostgreSQL (15분)

**RDS 콘솔 → Create database**

| 필드 | 값 |
|---|---|
| Engine type | **PostgreSQL** |
| Version | **PostgreSQL 17.x** (운영과 동일) |
| Template | **Free tier** ← (이거 선택하면 db.t3.micro/Single-AZ로 자동 설정) |
| DB instance identifier | `rais-poc-db` |
| Master username | `raisadmin` |
| Master password | `raisadmin` |
| **DB instance class** | **db.t3.micro** (1vCPU, 1GB) |
| Storage type | **gp2** (gp3는 프리티어 제외) |
| Allocated storage | **20 GB** |
| Storage autoscaling | ❌ **Disable** |
| **Multi-AZ** | ❌ **Do not create a standby** (Single-AZ) |
| VPC | rais-poc-vpc |
| Subnet group | (Create new — private subnets만 포함) ← **수동 생성 필요** |
| Public access | **No** |
| VPC security group | `rais-poc-db-sg` |
| Availability zone | ap-northeast-2a |
| Initial database name | `raisdb` |
| Backup retention | **1 day** (기본 7일 → 1일로 줄여서 스토리지 절약) |
| Encryption | (기본값) |
| Performance Insights | ❌ Disable |
| Enhanced monitoring | ❌ Disable |
| Auto minor version upgrade | ❌ Disable |
| **Deletion protection** | ❌ **Disable** ← cleanup 위해 반드시 OFF |
| Tags | 공통 |

⚠ **Subnet group 사전 생성 팁**: RDS 콘솔 좌측 **Subnet groups** → Create
- Name: `rais-poc-db-subnet-group`
- VPC: rais-poc-vpc
- AZs: 2a, 2c 선택
- Subnets: **private-2a, private-2c** 두 개만 추가

→ **Create database** (10~15분 소요. 그동안 다음 단계 진행 가능)

---

## 5. ElastiCache Redis (10분)

**ElastiCache 콘솔 → Redis OSS caches → Create Redis OSS cache**

| 필드 | 값 |
|---|---|
| Deployment option | **Design your own cache** |
| Creation method | **Easy create** |
| Configuration | **Demo** (가장 작은 것) |
| Name | `rais-poc-redis` |
| Engine version | 7.x |
| **Node type** | **cache.t3.micro** (운영의 t4g.micro는 그라비톤 — 신규 가입 무료라면 t3.micro 권장) |
| **Number of replicas** | **0** (운영은 1개지만 빈 PoC라 0) |
| Multi-AZ | ❌ Disabled |
| Subnet group | Create new: `rais-poc-redis-subnet-group` → private 서브넷 2개 |
| Security group | `rais-poc-redis-sg` |
| Backup | ❌ Disable |
| Tags | 공통 |

→ **Create** (5~10분)

---

## 6. ALB + Target Group (10분)

### 6-1. Target Group 먼저
**EC2 콘솔 → Target groups → Create target group**
- Target type: **IP addresses** (운영과 동일 — awsvpc 모드 ECS용)
- Name: `rais-poc-tg`
- Protocol: HTTP, Port: **8080**
- VPC: rais-poc-vpc
- Protocol version: HTTP1
- Health check path: `/` (운영은 `/actuator/health`인데 더미 nginx라 `/`)
- 다음 → **타겟 등록 없이** Create

### 6-2. ALB 생성
**EC2 콘솔 → Load Balancers → Create load balancer → Application Load Balancer**
- Name: `rais-poc-alb`
- Scheme: **Internet-facing**
- IP address type: IPv4
- VPC: rais-poc-vpc
- Mappings: **public-2a, public-2c** 둘 다 체크
- Security group: `rais-poc-alb-sg` (default 제거)
- Listener: HTTP 80 → forward to `rais-poc-tg`
- Tags: 공통

→ Create (2~3분)

⚠ **이 시점부터 ALB 시간당 과금 시작** ($0.0225/h)

---

## 7. EC2 Bastion (5분)

**EC2 콘솔 → Launch instance**

| 필드 | 값 |
|---|---|
| Name | `rais-poc-bastion` |
| AMI | **Amazon Linux 2023** |
| Instance type | **t3.nano** (운영 t3a.nano는 인텔 호환성 위해 t3로 변경 가능) |
| Key pair | **Proceed without** (SSM 사용) |
| VPC | rais-poc-vpc |
| Subnet | **private-2a** |
| Auto-assign public IP | Disable |
| Security group | `rais-poc-bastion-sg` |
| Storage | 8 GiB gp3 |
| **IAM instance profile** | `rais-poc-ssm-bastion-role` ← 중요 |
| Tags | 공통 |

→ Launch

> SSM 접속 확인: EC2 콘솔 → 인스턴스 선택 → **Connect** → **Session Manager** 탭 → Connect

---

## 8. ECS 클러스터 + 백엔드 배포 (30분)

### 8-1. ECR 리포지토리 생성 (콘솔)
**Amazon ECR 콘솔 → 프라이빗 리지스트리 → 리포지토리 → "리포지토리 생성"**

⚠ **리전 확인** — 화면 상단의 URL이 `*.dkr.ecr.**ap-northeast-2**.amazonaws.com` 인지 봐야 함. us-east-1 (ACM 인증서 만들 때 갔던 곳)이면 서울로 전환

| 필드 | 값 |
|---|---|
| Repository name | **`awsstudy/backend`** |
| Image tag mutability | Mutable (기본값) |
| Encryption | AES-256 (기본값) |
| Tags | 공통 |

→ 생성. 생성 후 리포 상세 → 태그 탭에서 공통 태그 추가 (UI가 별도일 경우)

### 8-2. 백엔드 이미지 빌드 + 푸시 (PowerShell 4줄)
```powershell
$ACCT = "<NEW_ACCOUNT_ID>"
$P    = "freetier"
$REG  = "$ACCT.dkr.ecr.ap-northeast-2.amazonaws.com"

# (1) ECR 로그인 — 임시 토큰 받아서 docker login 으로 전달
aws --profile $P ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $REG

# (2) 빌드 (첫 빌드는 gradle 의존성 다운로드 때문에 3~5분)
cd e:\awsStudy
docker build -t awsstudy/backend:latest .\backend

# (3) ECR 주소로 태그
docker tag awsstudy/backend:latest "$REG/awsstudy/backend:latest"

# (4) 푸시
docker push "$REG/awsstudy/backend:latest"
```

각 명령의 역할:
- (1) ECR이 12시간짜리 임시 비밀번호 발급 → docker login으로 파이프
- (2) Dockerfile의 multi-stage 빌드 (gradle 컨테이너로 jar 만들고 → temurin jre 컨테이너에 복사)
- (3) 같은 이미지에 ECR 주소를 라벨로 하나 더 붙임 (별명)
- (4) ECR로 업로드

### 8-3. ECS 클러스터 생성
**ECS 콘솔 → 클러스터 → 클러스터 생성**

| 필드 | 값 |
|---|---|
| Cluster name | `rais-poc-ecs-cluster` |
| Infrastructure | **Fargate 및 자체 관리형 인스턴스** ← 클래식 EC2 launch type |
| OS | Amazon Linux 2023 |
| **Instance type** | **t3.micro** (프리티어 무료) |
| Desired/Min/Max | **1 / 1 / 1** |
| EC2 instance role | `rais-poc-ecs-ec2-instance-role` |
| SSH key pair | 없음 |
| VPC | `rais-poc-vpc` |
| Subnets | **private 2개** |
| Security group | `rais-poc-ecs-sg` |
| Auto-assign public IP | OFF |
| Tags | 공통 |

→ 생성 (ASG 인스턴스 부팅 5~10분)

### 8-4. Task Definition 생성
**ECS 콘솔 → 태스크 정의 → 새 태스크 정의 생성**

| 필드 | 값 |
|---|---|
| Family | `rais-poc-backend` |
| Launch type | **EC2** |
| OS | Linux/X86_64 |
| Network mode | **awsvpc** |
| Task role | (비워두기) |
| Task execution role | `rais-poc-ecsTaskExecutionRole` |
| **Task size CPU** | **512 (0.5 vCPU)** |
| **Task size Memory** | **768 MB** ← 호스트 916 MB 중 750ish는 Spring Boot에 빠듯하지만 가능. 더 줄이면 OOM 위험 |

**Container `app` 설정**:

| 필드 | 값 |
|---|---|
| 이미지 URI | `<ACCT>.dkr.ecr.ap-northeast-2.amazonaws.com/awsstudy/backend:latest` |
| 포트 매핑 | 8080 TCP |
| 컨테이너 CPU | 512 |
| 컨테이너 메모리 (하드) | 768 |

**환경 변수** (6개):

| Key | Value |
|---|---|
| `DB_URL` | `jdbc:postgresql://<RDS_ENDPOINT>:5432/raisdb` |
| `DB_USERNAME` | `raisadmin` |
| `DB_PASSWORD` | `raisadmin` |
| `REDIS_HOST` | `<ELASTICACHE_PRIMARY_ENDPOINT>` |
| `REDIS_PORT` | `6379` |
| `REDIS_SSL` | `true` ← ElastiCache "Easy create" 기본이 TLS ON이라 필수 |

**컨테이너 health check** (운영 패턴 학습):
- Command: `CMD-SHELL,wget -qO- http://127.0.0.1:8080/actuator/health || exit 1`
- Interval: 30 / Timeout: 5 / Retries: 3 / **Start period: 60** (Spring Boot 부팅 시간 확보)

→ 생성

### 8-5. Service 생성
**클러스터 → 서비스 → 서비스 생성**

| 필드 | 값 |
|---|---|
| Compute config | Launch type = **EC2** |
| Task definition | `rais-poc-backend` (LATEST revision) |
| Service name | `rais-poc-backend-service` |
| Desired tasks | **1** |

⚠ **배포 옵션 (반드시 펼쳐서 변경)**:

| 필드 | 값 | 이유 |
|---|---|---|
| **Minimum running tasks (%)** | **0** | t3.micro는 ENI 한도(2개) + 메모리 916MB 라 task 2개 동시 못 띄움. 0으로 해야 옛 task 죽이고 → 새 task 시작 순서로 진행 |
| **Maximum running tasks (%)** | **100** | desired 넘지 않게 |

**Networking**:
- VPC: rais-poc-vpc
- Subnets: private 2개
- Security group: `rais-poc-ecs-sg`

**Load balancing**:
- Type: Application Load Balancer
- Use existing: `rais-poc-alb`
- Container: `app:8080`
- Target group: `rais-poc-tg`

- Tags: 공통

→ 생성. 첫 task 배치 + Spring Boot 부팅에 2~3분.

### 8-6. ALB Target Group health check 경로 변경
Target group 만들 때 health check path가 `/` 였을 텐데, Spring Boot 루트는 404. 변경해야 healthy 통과.

**EC2 → 대상 그룹 → `rais-poc-tg` → 상태 검사 탭 → 편집**
- 경로: **`/actuator/health`**
- 저장

---

## 9. S3 + CloudFront + (선택) 도메인 (20~40분)

### 9-1. S3 버킷 생성 + Vue 빌드 업로드
**S3 콘솔 → 버킷 만들기**

| 필드 | 값 |
|---|---|
| Name | `rais-poc-frontend-<your-account-id>` (글로벌 유니크) |
| Region | ap-northeast-2 |
| Block all public access | ✅ ON (OAC 사용해서 비공개 유지) |
| Tags | 공통 |

→ 생성

**Vue 빌드 + S3 업로드**:
```powershell
cd e:\awsStudy\frontend
npm install         # 첫 1회
npm run build       # dist/ 생성

aws --profile freetier s3 sync .\dist "s3://rais-poc-frontend-<ACCT>" --delete
```

`dist/`에 만들어지는 것:
- `index.html` (Vue 진입점) ← CloudFront의 Default root object가 가리킴
- `assets/index-XXXX.js` (Vue 코드 + axios 번들)
- `assets/index-XXXX.css`

### 9-2. CloudFront Distribution
**CloudFront 콘솔 → 배포 생성**

**Origins 2개**:
| Origin | Domain | 설정 |
|---|---|---|
| **S3** | `rais-poc-frontend-<ACCT>.s3.ap-northeast-2.amazonaws.com` | Origin access: **OAC** (Origin Access Control) → Create new OAC |
| **ALB** | `rais-poc-alb-XXXXX.ap-northeast-2.elb.amazonaws.com` | Protocol: HTTP only, port 80 |

**Behaviors 2개**:
| Path | Target Origin | Cache policy | Allowed methods |
|---|---|---|---|
| Default `*` | S3 | CachingOptimized | GET, HEAD |
| `/api/*` | ALB | **CachingDisabled** | **GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE** |

**기타**:
| 필드 | 값 |
|---|---|
| WAF | ❌ **Do not enable** (월정액 발생) |
| Price class | Use only North America and Europe (또는 All — 한국은 어차피 일본 엣지) |
| **Default root object** | **`index.html`** ← S3 루트 index.html 가리킴 |
| Alternate domain | (도메인 없으면 비워둠 / 있으면 §9-3에서 추가) |
| Tags | 공통 |

→ 생성 (deploy 15~20분)

**OAC 버킷 정책 적용**:
배포 생성 시 표시되는 S3 버킷 정책 JSON → **Copy** → S3 버킷의 **권한** 탭 → **버킷 정책 편집** → 붙여넣기

라우팅 결과:
- `/api/*` → ALB → ECS backend
- 그 외 (`/`, `/assets/*` 등) → S3 (Vue 빌드 결과)

### 9-3. (선택) 도메인 + TLS — Route53 + ACM

도메인 있으면 학습 권장. 비용: Hosted zone 월 $0.50 + ACM 인증서 무료.

#### A. ACM 인증서 발급 — **반드시 us-east-1 (버지니아)**
CloudFront에 붙일 인증서는 us-east-1에서만 발급해야 함.

1. 콘솔 우측 상단 리전 → **N. Virginia (us-east-1)** 으로 전환
2. **AWS Certificate Manager → 인증서 요청 → 퍼블릭**
3. 도메인 이름: `your-domain.com` + `*.your-domain.com` (와일드카드)
4. 검증 방법: **DNS validation**
5. 발급 후 인증서 상세 → **"Create records in Route 53"** 버튼 → 자동으로 검증 CNAME이 Route53에 추가됨
6. 5~30분 후 Status = **Issued**

#### B. CloudFront에 도메인 + 인증서 붙이기
1. CloudFront → distribution → 설정 → 편집
2. **Alternate domain name (CNAME)**: `your-domain.com`, `www.your-domain.com`
3. **Custom SSL certificate**: 위에서 발급받은 ACM 선택
4. 저장

#### C. Route53에서 도메인 → CloudFront alias
**리전을 다시 서울로 (Route53은 글로벌이지만 콘솔 UX)**
1. Route53 → Hosted zones → `your-domain.com`
2. **Create record**
3. Record name: 비워둠 (root) 또는 `www`
4. Record type: **A**
5. **Alias: ON** → CloudFront distribution 선택
6. Create
7. www도 추가하려면 1~6 반복 (record name: `www`)

→ `https://your-domain.com` 로 접속 가능. TLS 자물쇠 아이콘 확인.

---

## 10. 검증

### 10-1. ECS Task RUNNING + Target Healthy 확인
```powershell
$P = "freetier"

# ECS Service 상태
aws --profile $P ecs describe-services --cluster rais-poc-ecs-cluster --services rais-poc-backend-service `
    --query "services[0].{Running:runningCount,Pending:pendingCount}" --output table
# Running=1, Pending=0 보여야 OK

# ALB Target health
aws --profile $P elbv2 describe-target-health --target-group-arn <TG_ARN> `
    --query "TargetHealthDescriptions[].{IP:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" --output table
# State=healthy 보여야 OK
```

### 10-2. Spring Boot 부팅 로그 확인
**CloudWatch 콘솔 → 로그 그룹 `/ecs/rais-poc-backend` → 최근 stream**

찾을 메시지:
```
Started DemoApplication in XX.XXX seconds (process running for ...)
```
이 줄이 보이면 Spring Boot 정상 시작. Health check 통과까지 추가 30초.

### 10-3. (선택) Bastion SSM 접속 후 RDS/Redis 직접 검증
**EC2 → 인스턴스 → `rais-poc-bastion` → 연결 → Session Manager 탭 → 연결**

```bash
sudo dnf install -y postgresql17 redis6

# PostgreSQL
PGPASSWORD=raisadmin psql -h <RDS_ENDPOINT> -U raisadmin -d raisdb -c "SELECT version();"

# Redis (TLS 필수)
redis6-cli -h <REDIS_ENDPOINT> -p 6379 --tls PING
# → PONG
```

### 10-4. CloudFront 캐시 무효화 + 브라우저 접속
```powershell
aws --profile $P cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/*"
```

브라우저: `https://your-domain.com` (도메인 있으면) 또는 `https://dXXXX.cloudfront.net`

3개 카드 동작 확인:
- **호출 (`/api/hello`)** → JSON 응답에 컨테이너 호스트명 표시 = ALB → ECS → backend 통신 OK
- **메모 추가** → 새로고침해도 유지 = RDS 동작 OK
- **카운터 +1** → 숫자 증가 = ElastiCache 동작 OK

세 가지 다 되면 **인프라 + 앱 모두 정상**.

---

## 함정: 첫 배포 시 자주 만나는 문제

| 증상 | 원인 | 해결 |
|---|---|---|
| ECS task가 `Unable to attach network interface to unused device index` 로 죽음 | t3.micro ENI 한도 (2개) | 서비스의 **Min healthy %=0** 으로 (§8-5) |
| ECS task가 `insufficient memory` 로 안 뜸 | 호스트 916MB에 task 768MB 둘이 동시에 못 들어감 | 위와 동일. 옛 task 먼저 죽이기 |
| ALB Target unhealthy / 502 | Health check path가 `/` (Spring 루트는 404) | §8-6 에서 `/actuator/health` 로 변경 |
| Spring Boot 시작 시 Redis 연결 timeout | ElastiCache TLS 켜져있는데 `REDIS_SSL=true` 안 줌 | task definition env에 `REDIS_SSL=true` |
| Bastion에서 `redis-cli ... PING` 무응답 | TLS 켜져있어서 평문 PING 안 통함 | `redis6-cli ... --tls PING` |
| 브라우저에 옛 페이지 계속 보임 | CloudFront 캐시 | `create-invalidation --paths "/*"` |

→ 검증 끝났으면 **즉시 다음 단계 (삭제)** 진행

---

## 11. 삭제 (cleanup 스크립트 + 수동 정리)

### 11-1. 자동 정리 — `aws-cleanup.ps1`
```powershell
# 신규 프리티어 계정 프로파일로 실행 (운영 계정에 잘못 실행하지 않도록 주의!)
.\aws-cleanup.ps1 -Profile freetier

# 미리 무엇이 삭제될지만 보고 싶을 때
.\aws-cleanup.ps1 -Profile freetier -DryRun
```

스크립트가 의존성 순서대로 다음을 삭제:
1. ECS service desired=0 → service 삭제 → ASG 분리 → cluster 삭제
2. ALB → Target Group 삭제
3. CloudFront 비활성화 → 삭제 (최대 20분 대기)
4. S3 버킷 비우고 삭제
5. RDS 삭제 (snapshot skip)
6. ElastiCache 삭제
7. EC2 인스턴스 (Bastion + ECS 호스트 잔여) 종료
8. NAT Gateway 삭제 → EIP release
9. VPC Endpoint, Security Group, Subnet, IGW, RouteTable, VPC 삭제
10. IAM Role detach + 삭제
11. CloudWatch Log Group 삭제
12. ECR 리포지토리 삭제 (awsstudy/* 포함)

**식별 기준**: 태그 `Project=rais-poc` + 이름 패턴 `rais-poc*` / `awsstudy/*` (ECR/Log group).

### 11-2. 수동 정리 — Route53 + ACM (스크립트 미포함)

도메인/인증서는 학습 용도로 만든 거라 스크립트가 자동 삭제하지 않습니다. 명시적으로 안 쓸 거면 수동:

**ACM 인증서** (us-east-1):
1. 리전을 **N. Virginia** 로 전환
2. ACM → 인증서 → 발급받은 인증서 선택 → 삭제
3. ⚠ CloudFront에 연결돼있으면 먼저 연결 해제. CloudFront 자체 삭제 후엔 상관없음

**Route53 Hosted Zone**:
1. Route53 → Hosted zones → `your-domain.com`
2. 안의 record 중 **NS / SOA 빼고 전부 삭제** (CloudFront alias, ACM 검증 CNAME 등)
3. Hosted zone 자체 삭제
4. ⚠ 한 달 단위 청구라 이미 발생한 $0.50은 환불 안 됨. 다음 달 청구 막는 게 목적.

**도메인 자체** (가비아/Namecheap 등에서 산 것):
- 1년 단위 청구라 환불 안 됨
- 갱신만 안 하면 1년 후 자동 소멸

### 11-3. 정리 후 검증
```powershell
aws --profile freetier resourcegroupstaggingapi get-resources `
    --tag-filters "Key=Project,Values=rais-poc" `
    --query "ResourceTagMappingList[].ResourceARN" --output table
```
빈 결과면 태그 기반 리소스 완전 정리.

다음 날 Cost Explorer로 일 비용 < $0.01 확인하면 끝.

---

## 비용 정리

### 시간당 실비 (서울)
| 항목 | 시간당 USD | 24h | 비고 |
|---|---|---|---|
| NAT Gateway | $0.059 | $1.42 | + 데이터 처리 |
| ALB | $0.0225 | $0.54 | |
| RDS db.t3.micro Single-AZ | $0.026 | $0.62 | 12개월 무료 한도 차감 가능 |
| ElastiCache cache.t3.micro | $0.022 | $0.53 | 12개월 무료 한도 차감 가능 |
| EC2 t3.micro × 1 (ECS host) | $0.013 | $0.31 | 12개월 무료 한도 차감 |
| EC2 t3.nano (Bastion) | $0.0065 | $0.16 | |
| EBS (20+8+8 = 36GB gp3) | — | $0.10 | |
| **합계 (프리티어 무시)** | **~$0.155** | **~$3.70** | |
| **합계 (12개월 무료 적용)** | **~$0.10** | **~$2.40** | EC2/RDS/Redis 750h 무료 차감 |

### 즉시 청구 (만들면 바로 발생)
- 없음 (Route53/WAF/Security Hub 안 만듦)

### $10 학습비로 가능한 시간
- 프리티어 무시: ~64시간 (2.5일)
- 프리티어 적용: ~100시간 (4일)

→ **하루 만에 검증 후 즉시 삭제하면 $2~4 정도** 사용. 충분히 안전권.

---

## 함정 체크리스트 (삭제 시 빠뜨리기 쉬운 것)

- [ ] **EIP**: NAT GW 삭제 후에도 EIP는 따로 release 해야 함
- [ ] **CloudFront**: Disable → 배포 완료까지 15~20분 대기 후 Delete (스크립트가 처리)
- [ ] **S3**: 버킷 안 비우면 삭제 안 됨 (스크립트가 비움)
- [ ] **RDS**: Final snapshot 옵션을 skip (안 그러면 스냅샷 비용 잔여)
- [ ] **CloudWatch Log Group**: ECS/RDS가 만든 로그그룹 잔여
- [ ] **ECS Capacity Provider**: 클러스터 삭제 전에 ASG 분리 필요
- [ ] **IAM Role**: 정책 detach 후 삭제 가능

스크립트가 다 처리하지만 **삭제 후 콘솔에서 한 번 더 확인**: VPC가 사라졌으면 90% 정리된 것.

---

## 정리 후 검증

```powershell
# 모든 rais-poc 태그 리소스가 없는지 확인
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=rais-poc" --query "ResourceTagMappingList[].ResourceARN" --output table
```
빈 결과면 완전 정리 완료.

다음 날 Cost Explorer로 일 비용 < $0.01 확인하면 정말 끝.

---

# 📋 실제 구축 상태 (2026-05-22 실측 스냅샷)

> 가이드 작성 이후 실제 구축 + Cloud Map 트랙(운영 구조 재현) 추가까지 반영한 현재 상태.
> 계정: `389352668673` / 리전: `ap-northeast-2`

## A. 네트워크

| 항목 | 값 |
|---|---|
| VPC | `vpc-093329e78e20cab49` (10.0.0.0/16) |
| IGW | `igw-0dbbabb5205f78f09` |
| NAT GW | `nat-04ed1b20277839100` (public-2a) |
| Public subnet 2a | `subnet-0e48cf45706229ff3` (10.0.0.0/20) |
| Public subnet 2b | `subnet-063b0fbeea71cbe04` (10.0.16.0/20) |
| Private subnet 2a | `subnet-0ed0d7dabbb04bf97` (10.0.128.0/20) |
| Private subnet 2b | `subnet-0e3582ce734a84445` (10.0.144.0/20) |

> ⚠️ 가이드는 2a/2c로 적혀있지만 실제 VPC Wizard가 2a/2b로 만듦.

## B. Security Group (5개)

| 이름 | ID | Ingress |
|---|---|---|
| rais-poc-alb-sg | `sg-07f55765dcf96711c` | 80/443 from 0.0.0.0/0 |
| rais-poc-ecs-sg | `sg-0ac26710b877a7f34` | All TCP from alb-sg, bastion-sg, **self** (Service Discovery 내부 통신용) |
| rais-poc-db-sg | `sg-0c92062b1bccac180` | 5432 from ecs-sg, bastion-sg |
| rais-poc-redis-sg | `sg-0dd54ae031c337144` | 6379 from ecs-sg, bastion-sg |
| rais-poc-bastion-sg | `sg-0c7db4b56ebd26349` | (없음, SSM) |

## C. ALB / Target Group

| 항목 | 값 |
|---|---|
| ALB 이름 | `rais-poc-alb` |
| DNS | `rais-poc-alb-1681462476.ap-northeast-2.elb.amazonaws.com` |
| 리스너 | **HTTP 80 만** (HTTPS 443 미설치) ⚠️ |
| TG | `rais-poc-tg` (port 8080, target type IP / awsvpc) |
| Health check | `/actuator/health`, interval 30s, **healthy 3**, unhealthy 2 |

> 💡 `healthy 3`은 디버깅 중 5→3으로 변경한 값. 부팅 90초 + healthy 3×30s = 180s grace period에 정확히 맞춤.

## D. ECS

| 항목 | 값 |
|---|---|
| 클러스터 | `rais-poc-ecs-cluster` (active) |
| 호스트 (ASG) | `t3.micro × 2` (a/b AZ 각 1대) |
| ASG 이름 | `Infra-ECS-Cluster-rais-poc-ecs-cluster-7d8dffeb-ECSAutoScalingGroup-...` |
| Container Insights | **enhanced** ✅ (performance 로그그룹 `/aws/ecs/containerinsights/rais-poc-ecs-cluster/performance` 자동 생성, retention 1d) |
| 서비스 | `rais-poc-backend-service`, `rais-poc-worker-service` |
| Task definition (현재) | `rais-poc-backend:5`, `rais-poc-worker:N` |
| Network mode | `awsvpc` (task별 ENI) |

### ECS 호스트 EC2

| 이름 | ID | AZ | Private IP |
|---|---|---|---|
| ECS Instance #1 | `i-012d72f514c1064d5` | 2a | 10.0.133.80 |
| ECS Instance #2 | `i-0c7b1604c2596ee5e` | 2b | 10.0.145.68 |

## E. Bastion

| 항목 | 값 |
|---|---|
| ID | `i-092db6454f00b3f03` |
| Type | `t3.micro` (가이드는 t3.nano로 적힘) |
| Subnet | private-2a, 10.0.133.25 |
| 접속 | SSM Session Manager (포트 22 미개방) |

## F. RDS

| 항목 | 값 |
|---|---|
| ID | `rais-poc-db` |
| Engine | PostgreSQL **18.3** (가이드는 17.x 가정) |
| Class | `db.t4g.micro` (가이드는 db.t3.micro) |
| Storage | 20GB gp2, Single-AZ |
| Endpoint | `rais-poc-db.cdi2cg6kutc6.ap-northeast-2.rds.amazonaws.com:5432` |
| Public access | 비공개 |

## G. ElastiCache

| 항목 | 값 |
|---|---|
| Replication group | `rais-poc-redis` |
| Node | `rais-poc-redis-001` (cache.t3.micro × 1, Redis 7.1.0) |
| Primary endpoint | `master.rais-poc-redis.7gvykb.apn2.cache.amazonaws.com:6379` |
| TLS in-transit | **ON** |

## H. S3 + CloudFront

| 항목 | 값 |
|---|---|
| S3 bucket | `rais-poc-frontend-389352668673` |
| CloudFront ID | `EZT2JGL1MUCMZ` |
| Aliases | `raispoc.store`, `www.raispoc.store` |
| Origins | S3 (정적) + ALB (`/api/*`, **http-only**) ⚠️ |

## I. Route53 / ACM

| 항목 | 값 |
|---|---|
| Public zone | `raispoc.store.` (4 records) |
| **Private zone** | `rais-poc.local.` (4 records) — Cloud Map이 자동 생성 |
| ACM us-east-1 | `raispoc.store` (CloudFront용) ✅ |
| ACM ap-northeast-2 | **없음** ⚠️ (ALB HTTPS 미적용) |

## J. IAM Role

- `rais-poc-ecs-ec2-instance-role` (ECS 호스트 EC2용)
- `rais-poc-ecsTaskExecutionRole` (task execution + **Task Role 겸용**, SSM 권한 추가됨)
- `rais-poc-ssm-bastion-role` (Bastion SSM 접속용)
- `ecsInfrastructureRoleForManagedInstances` (AWS 자동)

## K. ECR

- `awsstudy/backend` (Spring Boot 이미지)

> 운영은 `rais/backend` + `rais/python` 2개. PoC는 worker용 별도 이미지 없이 nginx 더미 사용.

## L. Cloud Map (운영 구조 재현 트랙) ⭐

| 항목 | 값 |
|---|---|
| Namespace | `rais-poc.local` (`ns-ifzvyrm522vo7jzi`, DNS_PRIVATE) |
| Service: backend | `srv-qpspl7nwwzj5sacm` → `backend.rais-poc.local` |
| Service: worker | `srv-buzkgr7aqfazq3bx` → `worker.rais-poc.local` |
| DNS 레코드 (private zone 실측) | `backend.rais-poc.local A 10.0.144.239` / `worker.rais-poc.local A 10.0.129.106` |

→ 운영의 `rais.local.` private zone + ECS service-to-service 내부 DNS 패턴 재현 완료.
→ backend는 `worker.rais-poc.local`로 worker 호출 가능 (VPC 내부 한정).

## M. Secrets Manager ⭐ 추가

| 항목 | 값 |
|---|---|
| Secret 이름 | `rais-poc/db/credentials` |
| ARN | `arn:aws:secretsmanager:ap-northeast-2:389352668673:secret:rais-poc/db/credentials-YtNh52` |
| 키 | `username`, `password` |
| KMS | `alias/aws/secretsmanager` (AWS 관리 키) |
| 적용 위치 | Task definition `rais-poc-backend:5` → `secrets` 필드에서 `DB_USERNAME`, `DB_PASSWORD`로 주입 |

→ 운영 패턴: DB 자격증명을 평문 환경변수로 두지 않고 Secrets Manager에서 valueFrom으로 컨테이너에 주입.

## N. CloudWatch Alarms + SNS ⭐ 추가

| 알람 | 메트릭 | 임계값 | 액션 |
|---|---|---|---|
| `rais-poc-alb-5xx-alarm` | `AWS/ApplicationELB / HTTPCode_ELB_5XX_Count` | > 0 | SNS → email |
| (자동 생성) `TargetTracking-...AlarmHigh` | `AWS/ECS/ManagedScaling / CapacityProviderReservation` | > 100 | ASG 스케일 아웃 |
| (자동 생성) `TargetTracking-...AlarmLow` | 동일 | < 100 | ASG 스케일 인 |

**SNS Topic**: `rais-poc-alerts` → email 구독 `hongjeong135790@gmail.com`

## O. VPC Flow Logs ⭐ 추가

| 항목 | 값 |
|---|---|
| 로그그룹 | `/aws/vpc/rais-poc-flowlogs` |
| Retention | 미설정 (영구) |

→ VPC 내 모든 ENI 트래픽 메타데이터 수집. 운영도 보통 적용.

## P. ECS Exec ⭐ 추가

| 서비스 | enableExecuteCommand | 비고 |
|---|---|---|
| `rais-poc-backend-service` | **true** ✅ | 컨테이너 진입 가능 |
| `rais-poc-worker-service` | false | 검증 안 함 (backend → worker 단방향만) |

- Cluster `executeCommandConfiguration.logging`: `DEFAULT` (CloudWatch에 명령 로깅)
- Task Role `rais-poc-ecsTaskExecutionRole`에 `AmazonSSMManagedInstanceCore` 정책 추가됨

## Q. EBS / EIP

**EBS** (전체 in-use 68GB):
- bastion: 8GB gp3 (`vol-0362eb21ab1aa55ba`)
- ECS host #1: 30GB gp3 (`vol-023c7cb520c10a66e`)
- ECS host #2: 30GB gp3 (`vol-07163f5e463b6a2f9`)

**EIP** (3개, 모두 연결됨):
- `13.209.59.49`, `3.39.19.233`, `43.202.90.3` — NAT GW 1 + ALB IP 2

---

## 🔄 가이드와 실측 차이 요약

| 항목 | 가이드 | 실측 | 영향 |
|---|---|---|---|
| Subnet AZ | 2a/2c | **2a/2b** | 없음 (VPC Wizard 기본값) |
| Bastion 인스턴스 | t3.nano | **t3.micro** | 시간당 +$0.0065 |
| ECS 호스트 | 1대 | **2대** | 시간당 +$0.013 (Cloud Map 트랙용) |
| RDS 클래스 | db.t3.micro | **db.t4g.micro** | 거의 동일 (ARM, 약간 저렴) |
| Postgres 버전 | 17.x | **18.3** | 없음 |
| ECR repo 이름 | rais/backend | **awsstudy/backend** | 없음 |
| Cloud Map | 없음 | **추가됨** | 운영 구조 재현 |
| ALB Healthy threshold | (default 5) | **3** | 디버깅 중 변경 |
| Container Insights | 미언급 | **enhanced** | 운영 가시성 |
| Secrets Manager | 평문 ENV | **valueFrom 주입** | 운영 보안 패턴 |
| CloudWatch Alarm + SNS | 미언급 | **ALB 5xx → email** | 운영 알림 패턴 |
| ECS Exec (backend) | 미언급 | **활성화** | 컨테이너 디버깅 |
| VPC Flow Logs | 미언급 | **활성화** | 보안 가시성 |
| EBS 총량 | 36GB 추정 | **68GB 실측** | 시간당 +$0.005 |

## ✅ 완료 / 🚧 운영 대비 아직 안 한 것

**완료**
- [x] Cloud Map private namespace + ECS Service Discovery (운영 구조 재현)
- [x] Container Insights **enhanced**
- [x] Secrets Manager (DB 자격증명)
- [x] CloudWatch Alarm (ALB 5xx) + SNS email
- [x] ECS Exec (backend) + `worker.rais-poc.local` 내부 DNS 호출 최종 검증 ✅
- [x] VPC Flow Logs
- [x] ALB TG healthy threshold 튜닝 (5→3)

**미완 (선택 사항)**
- [ ] **ALB HTTPS 443 listener** (ACM ap-northeast-2 발급 필요) — 운영 ALB는 보유
- [ ] **추가 CloudWatch Alarm** — ECS task 정지, RDS CPU/Storage, ECS service desired vs running
- [ ] **GuardDuty / Security Hub** — 운영은 활성, PoC는 미적용
- [ ] **GitHub Actions OIDC** — 운영의 `cicd-deploy-role` 패턴
- [ ] **worker 서비스 ECS Exec 활성화** (현재 false, 양방향 호출 검증 시 필요)

## 💰 현재 시간당 비용 (실측 구성 기준)

| 리소스 | 시간당 USD | 비고 |
|---|---|---|
| NAT GW | $0.045 | |
| ALB | $0.0225 | |
| ElastiCache t3.micro | $0.022 | |
| Public IPv4 × 3 (ALB 2 + NAT 1) | $0.015 | |
| EC2 t3.micro × 3 (ECS×2 + Bastion) | $0.031 | 프리티어 750h 1대 무료 |
| RDS db.t4g.micro | $0.018 | 프리티어 750h 무료 |
| EBS 68GB gp3 | $0.011 | 일부 프리티어 |
| Secrets Manager × 1 | $0.0006 | $0.40/월 |
| CloudWatch Logs (Insights performance) | 가변 | retention 1d로 최소화 |
| **합계 (프리티어 제외)** | **~$0.166/h** | 24h ≈ $3.98 |
| **합계 (프리티어 적용)** | **~$0.11/h** | 24h ≈ $2.64 |

