# awsStudy

운영 RAIS 인프라(VPC + NAT + ALB + ECS + RDS + ElastiCache + CloudFront)를 **프리티어로 똑같이 띄워보고 검증**하기 위한 더미 풀스택 데모.

| 컴포넌트 | 스택 | 포트 |
|---|---|---|
| Backend | Spring Boot 3.4 + Java 21 + JPA + Lettuce | 8080 |
| Frontend | Vue 3 + Vite 6 + axios | 80 (nginx) / 5173 (dev) |
| DB | PostgreSQL 17 | 5432 |
| Cache | Redis 7 | 6379 |

## 제공 API

| 메서드 | 경로 | 설명 | 검증 대상 |
|---|---|---|---|
| GET | `/api/hello` | 인삿말 + 컨테이너 호스트명 + 시각 | ALB → ECS → 컨테이너 라우팅 |
| GET | `/api/notes` | 메모 전체 조회 (id 내림차순) | RDS PostgreSQL |
| POST | `/api/notes` | `{ "content": "..." }` 저장 | RDS PostgreSQL |
| GET | `/api/counter` | Redis `INCR` 카운터 | ElastiCache Redis |
| GET | `/actuator/health` | Spring 헬스체크 | ALB target health |

---

## 로컬 개발 (docker-compose 한 방)

```powershell
# 처음 한 번 — 이미지 빌드 + 컨테이너 실행
docker compose up --build -d

# 로그 확인
docker compose logs -f backend

# 종료 + 볼륨까지 정리
docker compose down -v
```

접속:
- Frontend: http://localhost:8081
- Backend:  http://localhost:8080/api/hello
- Health:   http://localhost:8080/actuator/health

### 프론트엔드만 핫리로드 (선택)

백엔드는 컨테이너로 두고 프론트만 로컬 vite로 띄우는 경우:

```powershell
# 백엔드 + DB + Redis 만 컨테이너로
docker compose up -d postgres redis backend

# 프론트는 호스트에서 (vite proxy가 /api → localhost:8080 으로 보냄)
cd frontend
npm install
npm run dev
# http://localhost:5173
```

---

## 디렉토리 구조

```
awsStudy/
├── backend/                       Spring Boot
│   ├── src/main/java/com/awsstudy/demo/
│   │   ├── DemoApplication.java
│   │   ├── config/WebConfig.java       (CORS)
│   │   ├── hello/HelloController.java
│   │   ├── note/                       (JPA Entity + Repository + Controller)
│   │   └── counter/CounterController.java
│   ├── src/main/resources/application.yml
│   ├── build.gradle.kts
│   ├── settings.gradle.kts
│   └── Dockerfile                  (multi-stage: gradle build → temurin jre)
├── frontend/                       Vue 3 + Vite
│   ├── src/
│   │   ├── App.vue
│   │   ├── main.js
│   │   └── api.js
│   ├── index.html
│   ├── vite.config.js
│   ├── package.json
│   ├── nginx.conf                  (envsubst 템플릿)
│   └── Dockerfile                  (multi-stage: vite build → nginx alpine)
├── docker-compose.yml
├── ecr-push.ps1                    (ECR 빌드+푸시 자동화)
└── README.md
```

> Gradle wrapper(`gradlew`, `gradle/wrapper/`) 파일은 포함되어 있지 않습니다. Docker 빌드는 stage 안에서 `gradle:8.10-jdk21-alpine` 이미지를 사용하므로 호스트에 Gradle/JDK 설치 없이도 동작합니다. IDE에서 직접 개발하고 싶다면 프로젝트 루트(`backend/`)에서 `gradle wrapper` 한 번 실행해 wrapper를 추가하세요.

---

## AWS ECR 푸시 + ECS 배포

[AWS_FREETIER_SETUP_GUIDE.md](../rais-front/AWS_FREETIER_SETUP_GUIDE.md) 가이드로 인프라 먼저 구축한 뒤 다음 흐름으로 이미지 교체.

### 1) ECR 푸시

```powershell
# 신규 프리티어 계정 ID + 프로파일 지정
.\ecr-push.ps1 -AccountId <NEW_ACCOUNT_ID> -Profile freetier

# 한 쪽만 다시 빌드/푸시
.\ecr-push.ps1 -AccountId <NEW_ACCOUNT_ID> -Profile freetier -Service backend
```

스크립트가 자동으로:
1. `awsstudy/backend`, `awsstudy/frontend` ECR 리포지토리 생성 (없으면)
2. Docker 로그인
3. 이미지 빌드 → `:YYYYMMDD-HHMM` + `:latest` 두 태그로 푸시

### 2) ECS Task Definition 업데이트

콘솔 가이드에서 만든 더미 nginx 태스크 정의를 다음 두 개로 교체합니다.

#### `rais-poc-backend` (수정)
| 필드 | 값 |
|---|---|
| Container name | `app` |
| Image | `<acct>.dkr.ecr.ap-northeast-2.amazonaws.com/awsstudy/backend:latest` |
| Port mappings | 8080 TCP |
| Memory hard limit | 768 MB |
| CPU | 256 |
| Environment | `DB_URL=jdbc:postgresql://<rds-endpoint>:5432/awsstudy` |
|              | `DB_USERNAME=raisadmin` |
|              | `DB_PASSWORD=...` (또는 Secrets Manager 참조) |
|              | `REDIS_HOST=<elasticache-endpoint>` |
|              | `REDIS_PORT=6379` |
| Health check | `wget -qO- http://127.0.0.1:8080/actuator/health \|\| exit 1` |

#### `rais-poc-frontend` (신규)
| 필드 | 값 |
|---|---|
| Container name | `app` |
| Image | `<acct>.dkr.ecr.ap-northeast-2.amazonaws.com/awsstudy/frontend:latest` |
| Port mappings | 80 TCP |
| Memory hard limit | 128 MB |
| CPU | 128 |
| Environment | `BACKEND_HOST=<backend-internal-dns-or-alb>` |

### 3) ECS Service 업데이트
- 기존 `rais-poc-backend-service` 의 task definition을 새 버전으로 update → Force new deployment
- 필요하면 `rais-poc-frontend-service` 신규 생성 (ALB 다른 listener rule 또는 path로 라우팅)

### 4) 검증
- ALB DNS 또는 CloudFront URL에서 Vue 페이지 보임
- "호출" 버튼 → `/api/hello` 응답 (host에 컨테이너 ID 보임)
- 메모 추가 → 새로고침해도 유지 (RDS)
- 카운터 +1 → 증가 (Redis)

### 5) 검증 끝났으면 즉시 삭제
```powershell
cd ..\rais-front
.\aws-cleanup.ps1 -Profile freetier
```

ECR 리포지토리도 cleanup 스크립트가 `Project=rais-poc` 태그 기준으로 삭제합니다.

---

## 환경변수 요약

| 변수 | 기본값 (local) | 운영(ECS)에서 |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/awsstudy` | RDS endpoint |
| `DB_USERNAME` | `awsstudy` | RDS master 계정 |
| `DB_PASSWORD` | `awsstudy` | Secrets Manager 또는 평문 |
| `REDIS_HOST` | `localhost` | ElastiCache endpoint |
| `REDIS_PORT` | `6379` | `6379` |
| `BACKEND_HOST` | `backend` (compose) | nginx가 proxy_pass 할 백엔드 호스트 |

---

## 트러블슈팅

- **`docker compose up` 시 backend가 unhealthy** → 처음 빌드는 gradle 의존성 다운로드로 5분 이상 걸릴 수 있음. `docker compose logs backend` 로 확인
- **frontend가 502** → backend 헬스체크 통과 후 시작. `docker compose ps` 로 backend `healthy` 확인
- **ECS task 가 시작 안 됨** → CloudWatch 로그그룹 `/ecs/rais-poc-backend` 확인. 보통 환경변수 누락
- **메모 추가 안 됨** → RDS SG에 ECS SG inbound 5432 룰 있는지 확인. application.yml의 `ddl-auto: update` 가 첫 실행 시 `notes` 테이블 자동 생성
