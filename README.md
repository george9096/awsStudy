# awsStudy

운영 RAIS 인프라(VPC + NAT + ALB + ECS + RDS + ElastiCache + CloudFront + S3)를 **프리티어로 똑같이 띄워보고 검증**하기 위한 더미 풀스택 데모.

| 컴포넌트 | 스택 | 배포 방식 | 포트 |
|---|---|---|---|
| Backend | Spring Boot 3.4 + Java 21 + JPA + Lombok | Docker → ECR → ECS | 8080 |
| Frontend | Vue 3 + Vite 6 + axios | `npm run build` → **S3 정적 호스팅** | 5173 (dev) |
| DB | PostgreSQL 17 | RDS (운영), 로컬 docker | 5432 |
| Cache | Redis 7 | ElastiCache (운영), 로컬 docker | 6379 |

## 제공 API

| 메서드 | 경로 | 설명 | 검증 대상 |
|---|---|---|---|
| GET | `/api/hello` | 인삿말 + 컨테이너 호스트명 + 시각 | ALB → ECS → 컨테이너 |
| GET | `/api/notes` | 메모 전체 조회 (id 내림차순) | RDS PostgreSQL |
| POST | `/api/notes` | `{ "content": "..." }` 저장 | RDS PostgreSQL |
| GET | `/api/counter` | Redis `INCR` 카운터 | ElastiCache Redis |
| GET | `/actuator/health` | Spring 헬스체크 | ALB target health |

---

## 로컬 개발

운영 패턴(프론트 S3 + 백엔드 ECS)을 따르기 때문에 로컬도 **백엔드는 컨테이너, 프론트는 vite dev server**로 분리합니다.

### 1) 백엔드 + DB + Redis (한 줄로 컨테이너 실행)

```powershell
cd e:\awsStudy
docker compose up --build -d

# 로그 확인
docker compose logs -f backend

# 끄기
docker compose down -v
```

backend 컨테이너가 healthy 상태가 될 때까지 약 30초~1분 소요.

확인:
- Backend: http://localhost:8080/api/hello
- Health:  http://localhost:8080/actuator/health

### 2) 프론트엔드 (호스트에서 vite)

```powershell
cd e:\awsStudy\frontend
npm install        # 첫 1회만
npm run dev
```

- 접속: http://localhost:5173
- `vite.config.js`에 `/api → http://localhost:8080` 프록시가 설정돼있어서 백엔드 컨테이너로 자동 연결됨
- 코드 수정 시 핫 리로드 동작

---

## 디렉토리 구조

```
awsStudy/
├── backend/                        Spring Boot (Docker로 ECR/ECS)
│   ├── src/main/java/com/awsstudy/demo/
│   │   ├── DemoApplication.java
│   │   ├── config/WebConfig.java       (CORS — S3/CloudFront 환경에선 사실 동일 origin이라 불필요하지만 dev proxy 환경 호환용)
│   │   ├── hello/HelloController.java
│   │   ├── note/                       (JPA Entity + Repository + Controller)
│   │   └── counter/CounterController.java
│   ├── src/main/resources/application.yml
│   ├── build.gradle
│   ├── settings.gradle
│   └── Dockerfile                  (multi-stage: gradle:8.10-jdk21 build → temurin 21 jre)
├── frontend/                       Vue 3 (S3로 배포)
│   ├── src/
│   │   ├── App.vue
│   │   ├── main.js
│   │   └── api.js
│   ├── index.html
│   ├── vite.config.js              (dev proxy: /api → :8080)
│   └── package.json
├── docker-compose.yml              (로컬 개발용 — backend + postgres + redis)
└── README.md
```

> Gradle wrapper(`gradlew`)는 포함되지 않습니다. Docker 빌드는 `gradle:8.10-jdk21-alpine` 이미지를 사용하므로 호스트에 Gradle/JDK 설치 없이 동작합니다.

---

## AWS 배포 (프리티어)

[AWS_FREETIER_SETUP_GUIDE.md](../rais-front/AWS_FREETIER_SETUP_GUIDE.md) 로 인프라 구축한 뒤:

### 1) 백엔드: ECR 푸시 → ECS

#### 1-1. ECR 리포지토리 생성 (콘솔에서 한 번만)
1. AWS 콘솔 → **ECR** → "Create repository"
2. Repository name: **`awsstudy/backend`**
3. Tags: `Project=rais-poc`, `Owner=jw.hong`
4. Create

#### 1-2. 빌드 + 푸시 (PowerShell 4줄)
```powershell
$ACCT = "<NEW_ACCOUNT_ID>"   # 예: 389352668673
$P    = "freetier"
$REG  = "$ACCT.dkr.ecr.ap-northeast-2.amazonaws.com"

# (1) Docker가 ECR에 로그인 — AWS에서 임시 토큰 받아 docker login에 전달
aws --profile $P ecr get-login-password | docker login --username AWS --password-stdin $REG

# (2) 이미지 빌드 (backend 폴더의 Dockerfile 사용)
cd e:\awsStudy
docker build -t awsstudy/backend:latest .\backend

# (3) ECR 주소로 태그
docker tag awsstudy/backend:latest "$REG/awsstudy/backend:latest"

# (4) 푸시
docker push "$REG/awsstudy/backend:latest"
```

각 명령이 뭘 하는지:
- (1) `get-login-password` — ECR이 발급하는 12시간짜리 임시 비밀번호. 그걸 `docker login`에 파이프로 넘김
- (2) `docker build` — Dockerfile 보고 멀티스테이지 빌드 (gradle 컨테이너에서 jar 만들고, 그걸 jre 컨테이너에 복사)
- (3) `docker tag` — 같은 이미지에 ECR 주소 라벨 하나 더 붙이기 (별명 만들기)
- (4) `docker push` — 그 라벨로 가는 곳(=ECR) 으로 업로드

푸시 끝나면 ECS Task Definition을 새 이미지 URI로 업데이트 → Service force new deployment.

#### ECS Task Definition 권장 환경변수

| Key | Value |
|---|---|
| `DB_URL` | `jdbc:postgresql://<rds-endpoint>:5432/awsstudy` |
| `DB_USERNAME` | `raisadmin` |
| `DB_PASSWORD` | (Secrets Manager 참조 또는 평문) |
| `REDIS_HOST` | `<elasticache-endpoint>` |
| `REDIS_PORT` | `6379` |

### 2) 프론트엔드: 빌드 → S3 업로드 → CloudFront 캐시 무효화

```powershell
cd e:\awsStudy\frontend
npm run build

# dist/ 폴더 통째로 S3에 동기화
aws s3 sync .\dist s3://<frontend-bucket-name> --profile freetier --delete

# CloudFront 캐시 무효화 (옵션)
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/*" --profile freetier
```

`<frontend-bucket-name>` 은 인프라 가이드 Step 9에서 만든 S3 버킷.

### 3) CloudFront Behavior 라우팅

- 기본 (`*`) → S3 origin (정적 파일)
- `/api/*` → ALB origin (백엔드)
- `/actuator/*` → ALB origin (선택, health 체크 용도)

세부 가이드는 [AWS_FREETIER_SETUP_GUIDE.md](../rais-front/AWS_FREETIER_SETUP_GUIDE.md) §9-2 참고.

### 4) 검증

CloudFront URL에서:
- Vue 페이지 보임 (S3에서 로드)
- "호출" 버튼 클릭 → `/api/hello` 응답 (ALB → ECS → backend)
- 메모 추가 → 새로고침해도 유지 (RDS)
- 카운터 +1 → 증가 (Redis)

### 5) 검증 끝났으면 즉시 삭제
```powershell
cd ..\rais-front
.\aws-cleanup.ps1 -Profile freetier
```

---

## 환경변수 요약

| 변수 | 어디서 사용 | 로컬 기본값 | AWS 운영값 |
|---|---|---|---|
| `DB_URL` | backend | `jdbc:postgresql://postgres:5432/awsstudy` (compose) | RDS endpoint |
| `DB_USERNAME` | backend | `awsstudy` | RDS master 계정 |
| `DB_PASSWORD` | backend | `awsstudy` | Secrets Manager 또는 평문 |
| `REDIS_HOST` | backend | `redis` (compose) | ElastiCache endpoint |
| `REDIS_PORT` | backend | `6379` | `6379` |

프론트엔드는 빌드 시점에 결정되므로 환경변수가 필요 없습니다. 모든 API 호출이 `/api/*` 라는 상대 경로라서 CloudFront가 알아서 백엔드로 보냅니다.

---

## 트러블슈팅

- **`docker compose up`이 backend 빌드에서 5분 이상 멈춤** → gradle 의존성 첫 다운로드. `docker compose logs backend` 로 진행 상황 확인
- **vite dev에서 `/api` 호출이 CORS 에러** → backend의 `WebConfig.java` 가 CORS `*` 허용 중. 그래도 안 되면 backend 컨테이너 떠있는지 확인 (`http://localhost:8080/actuator/health`)
- **S3 sync 후 CloudFront에서 옛 페이지가 보임** → 캐시 무효화 (`create-invalidation --paths "/*"`) 또는 5분 대기
- **ECS task RUNNING 안 됨** → CloudWatch 로그그룹 `/ecs/rais-poc-backend` 확인. 보통 환경변수 누락 또는 SG의 DB/Redis 포트 차단
- **메모 추가 안 됨** → application.yml의 `ddl-auto: update` 가 첫 실행 시 `notes` 테이블 자동 생성. RDS SG inbound 5432 from ECS SG 확인
