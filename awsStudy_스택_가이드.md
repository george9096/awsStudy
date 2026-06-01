# awsStudy 프로젝트 스택·파일 가이드

> 사이드 프로젝트 베이스로 활용. 어디부터 봐야 하는지 + 무엇을 학습해야 하는지 정리.

## 목차
1. [전체 스택 인벤토리](#1-전체-스택-인벤토리)
2. [폴더 구조](#2-폴더-구조)
3. [백엔드 주요 파일](#3-백엔드-주요-파일)
4. [프론트엔드 주요 파일](#4-프론트엔드-주요-파일)
5. [인프라 파일](#5-인프라-파일)
6. [학습 우선순위](#6-학습-우선순위)
7. [실행 방법](#7-실행-방법)
8. [사이드 시작 시 손볼 곳](#8-사이드-시작-시-손볼-곳)

---

## 1. 전체 스택 인벤토리

### 1.1 백엔드 (Spring Boot)

| 항목 | 버전·내용 | 어디 확인 |
|---|---|---|
| Java | 21 (Toolchain) | `backend/build.gradle:10-14` |
| Spring Boot | 3.4.1 (LTS) | `backend/build.gradle:3` |
| 빌드 도구 | Gradle (Groovy) | `backend/build.gradle` |
| Web | spring-boot-starter-web | `backend/build.gradle:21` |
| ORM | spring-boot-starter-data-jpa + Hibernate | `backend/build.gradle:22` |
| 캐시·세션 | spring-boot-starter-data-redis | `backend/build.gradle:23` |
| 모니터링 | spring-boot-starter-actuator | `backend/build.gradle:24` |
| DB Driver | PostgreSQL (runtime) | `backend/build.gradle:25` |
| Lombok | 1.18.36 (annotationProcessor) | `backend/build.gradle:27-28` |
| 테스트 | spring-boot-starter-test (JUnit5) | `backend/build.gradle:30` |

### 1.2 프론트엔드 (Vue 3)

| 항목 | 버전·내용 | 어디 확인 |
|---|---|---|
| Vue | 3.5.13 (Composition API) | `frontend/package.json:13` |
| 빌드 도구 | Vite 6.0.7 | `frontend/package.json:17` |
| Vue 플러그인 | @vitejs/plugin-vue 5.2.1 | `frontend/package.json:16` |
| HTTP 클라이언트 | axios 1.7.9 | `frontend/package.json:12` |
| TypeScript | ❌ 미설치 (나중에 도입) | - |
| 라우터 | ❌ 미설치 (단일 페이지 PoC) | - |
| 상태관리 (Pinia) | ❌ 미설치 (PoC 단계) | - |

### 1.3 인프라

| 항목 | 버전·내용 | 어디 확인 |
|---|---|---|
| Docker compose | services × 3 | `docker-compose.yml` |
| PostgreSQL | 17-alpine | `docker-compose.yml:5` |
| Redis | 7-alpine | `docker-compose.yml:21` |
| Backend Dockerfile | Multi-stage (gradle build + temurin jre) | `backend/Dockerfile` |
| Vite dev proxy | /api → localhost:8080 | `frontend/vite.config.js:10-13` |
| AWS 가이드 | Free Tier 셋업 33KB | `AWS_FREETIER_SETUP_GUIDE.md` |
| AWS 정리 스크립트 | PowerShell | `aws-cleanup.ps1` |

---

## 2. 폴더 구조

```
e:\awsStudy\
├── README.md                       프로젝트 개요
├── AWS_FREETIER_SETUP_GUIDE.md     AWS 배포 33KB 가이드
├── aws-cleanup.ps1                 AWS 자원 일괄 정리
├── docker-compose.yml              로컬 DB + Redis + Backend 실행
├── .gitignore
│
├── backend/                        Spring Boot 프로젝트
│   ├── build.gradle                의존성·빌드 설정
│   ├── settings.gradle             멀티모듈 설정
│   ├── Dockerfile                  멀티스테이지 빌드
│   └── src/
│       ├── main/
│       │   ├── java/com/awsstudy/demo/
│       │   │   ├── DemoApplication.java         앱 진입점
│       │   │   ├── config/
│       │   │   │   └── WebConfig.java           CORS 설정
│       │   │   ├── hello/
│       │   │   │   └── HelloController.java     기본 API
│       │   │   ├── counter/
│       │   │   │   └── CounterController.java   Redis 카운터
│       │   │   └── note/                        ★ JPA 학습 핵심
│       │   │       ├── Note.java                엔티티
│       │   │       ├── NoteRepository.java      JpaRepository
│       │   │       └── NoteController.java      REST + DI
│       │   └── resources/
│       │       └── application.yml              DB·Redis·Actuator 설정
│       └── test/                                테스트 (현재 비어있음)
│
└── frontend/                       Vue 3 프로젝트
    ├── package.json                의존성
    ├── vite.config.js              dev 서버 + /api 프록시
    ├── index.html
    └── src/
        ├── main.js                 Vue 진입점
        ├── App.vue                 메인 컴포넌트 (3개 PoC)
        └── api.js                  axios 인스턴스 + API 함수
```

---

## 3. 백엔드 주요 파일

### 3.1 `backend/build.gradle` — 의존성 (★ 필수)

**봐야 할 라인:**
- `3` : Spring Boot 3.4.1 (LTS 버전 — 학습 자료 풍부)
- `10-14` : Java 21 Toolchain (자동 JDK 설치)
- `20-31` : dependencies 블록

**학습 포인트:**
- `compileOnly` + `annotationProcessor` 조합 → Lombok 작동 원리
- `runtimeOnly` → 런타임에만 필요한 의존성 (PostgreSQL Driver)
- `testImplementation` → 테스트 전용 의존성

### 3.2 `DemoApplication.java` — 진입점

**봐야 할 라인:**
- `6` : `@SpringBootApplication` (가장 중요한 어노테이션)
- `9` : `SpringApplication.run()` (부트 시작)

**학습 포인트:**
- `@SpringBootApplication` = `@Configuration` + `@EnableAutoConfiguration` + `@ComponentScan` 합본
- 이 한 어노테이션이 자동 설정·빈 스캔·설정 클래스 다 처리

### 3.3 `application.yml` — 설정 (★ 매우 중요)

**봐야 할 라인:**
- `1-2` : `server.port: 8080` — 포트 설정
- `7-11` : `datasource` — DB 연결 (환경변수 우선, 없으면 기본값)
- `12-19` : `jpa` 설정
  - `ddl-auto: update` — 엔티티 변경 시 테이블 자동 갱신 (개발용)
  - `open-in-view: false` — 영속성 컨텍스트 컨트롤러까지 안 끌고 감 (베스트 프랙티스)
  - `dialect: PostgreSQLDialect` — Hibernate가 DB 방언 선택
- `20-26` : Redis 연결 설정
- `28-37` : Actuator (`/actuator/health` 등 노출)

**학습 포인트:**
- `${DB_URL:기본값}` 패턴 = 환경변수 우선, 없으면 기본값 → 개발/운영 환경 분리
- `ddl-auto` 옵션 차이 (none / validate / update / create / create-drop)
- `open-in-view`가 N+1 문제와 LazyInitializationException에 미치는 영향

### 3.4 `WebConfig.java` — CORS 설정

**봐야 할 라인:**
- `7` : `@Configuration` — 설정 클래스 표시
- `8` : `WebMvcConfigurer` 구현 — Spring MVC 커스터마이징
- `11-14` : CORS 정책 (모든 origin/method/header 허용)

**학습 포인트:**
- 프론트(5173) → 백(8080) 다른 포트 = CORS 필요
- 운영에선 `allowedOriginPatterns("*")` 금지 (보안)
- 실제로는 `https://본인도메인.com` 지정 권장

### 3.5 `hello/HelloController.java` — 기본 API

**봐야 할 라인:**
- `10` : `@RestController` — JSON 반환 컨트롤러
- `11` : `@RequestMapping("/api")` — base path
- `14` : `@GetMapping("/hello")` — GET /api/hello

**학습 포인트:**
- `@Controller` vs `@RestController` 차이 (Rest는 자동 JSON 직렬화)
- `Map.of(...)` 반환 → JSON으로 자동 변환 (Jackson)

### 3.6 `note/Note.java` — JPA 엔티티 (★★ 최우선 학습)

**봐야 할 라인 전부:**
- `16` : `@Entity` — JPA 엔티티 등록
- `17` : `@Table(name = "notes")` — 테이블 이름 매핑
- `18-20` : Lombok 사용 — `@Getter`, `@Setter`, `@NoArgsConstructor`
- `23-25` : `@Id` + `@GeneratedValue(strategy = IDENTITY)` — PK 자동증가
- `27-28` : `@Column(nullable = false, length = 500)` — 컬럼 제약
- `30-31` : `@Column(name = "created_at")` — 컬럼명 매핑
- `33-36` : `@PrePersist` — 저장 직전 콜백

**학습 포인트 (부트 30% 지식 핵심):**
- `@Entity`로 등록 = JPA가 영속성 컨텍스트에서 관리
- `@GeneratedValue` 전략 차이 (IDENTITY / SEQUENCE / TABLE / AUTO)
- `@PrePersist`, `@PreUpdate` 등 라이프사이클 콜백
- Lombok이 왜 JPA 엔티티에 위험할 수 있는지 (`@EqualsAndHashCode`, `@ToString` 무한루프)
- `@NoArgsConstructor`가 JPA에 필수인 이유 (proxy 생성)

### 3.7 `note/NoteRepository.java` — Repository (★★ 필수)

**봐야 할 라인:**
- `1-5` : 한 줄로 끝나는 강력함

**학습 포인트:**
- `JpaRepository<Note, Long>` 상속 → 자동으로 CRUD 메서드 다 제공 (findAll, findById, save, delete)
- 메서드 이름 규칙으로 쿼리 자동 생성 (`findByContent(String content)` 같은 거)
- `@Query` 어노테이션으로 JPQL 직접 작성 가능
- 페이징·정렬은 `Pageable`, `Sort` 파라미터로

### 3.8 `note/NoteController.java` — REST + DI (★ 필수)

**봐야 할 라인:**
- `14` : `@RestController` + `@RequestMapping("/api/notes")` 조합
- `16` : `@RequiredArgsConstructor` — Lombok 생성자 주입 (★ 베스트 프랙티스)
- `19` : `private final NoteRepository repository` — 불변 의존성
- `21-24` : `@GetMapping` + `Sort.by(DESC, "id")` — 정렬
- `26-31` : `@PostMapping` + `@RequestBody Map` — JSON 입력

**학습 포인트:**
- 생성자 주입 vs 필드 주입(`@Autowired`) — 왜 생성자가 베스트인지
- `@RequiredArgsConstructor`가 `private final` 필드의 생성자 자동 생성
- `@RequestBody`로 JSON → 객체 자동 변환
- 더 좋은 패턴 : `Map` 대신 DTO 클래스 사용 (`CreateNoteRequest`)
- 컨트롤러에서 바로 `Repository` 사용 X — 보통 Service 레이어 끼움

### 3.9 `counter/CounterController.java` — Redis 활용

**봐야 할 라인:**
- `14` : Redis 키 상수 (네임스페이스 패턴)
- `15` : `StringRedisTemplate` — Spring Data Redis 핵심 클래스
- `17-19` : 생성자 주입 (★ 위 NoteController와 비교)
- `23` : `redis.opsForValue().increment(KEY)` — 원자적 증가

**학습 포인트:**
- Redis가 단일 명령으로 동시성 보장 (INCR atomic)
- `StringRedisTemplate` vs `RedisTemplate<K,V>` 차이
- Redis 데이터 타입별 ops (Value, List, Set, Hash, ZSet)
- 첫 사이드엔 Redis 사용 안 해도 됨 (학습 단계에서 자연 도입)

---

## 4. 프론트엔드 주요 파일

### 4.1 `package.json` — 의존성

**봐야 할 라인:**
- `5` : `"type": "module"` — ES Module 사용
- `7-10` : scripts (`dev`, `build`, `preview`)
- `12-13` : runtime 의존성 (axios, vue)
- `15-18` : dev 의존성 (vite, vue plugin)

### 4.2 `src/main.js` — 진입점

**봐야 할 라인 전부 (4줄):**
- `1` : Vue 3 createApp import
- `4` : `createApp(App).mount('#app')`

**학습 포인트:**
- Vue 3는 createApp 패턴 (Vue 2의 `new Vue()` 다름)
- `index.html`의 `<div id="app"></div>`에 마운트

### 4.3 `src/App.vue` — 메인 컴포넌트 (★ Vue 3 Composition API 학습)

**봐야 할 라인:**
- `1` : `<script setup>` — Composition API 단축 문법
- `2` : `import { ref, onMounted } from 'vue'`
- `5-9` : `ref()` 로 반응성 변수 선언
- `12-19` : async 함수 + try/catch 패턴
- `46-49` : `onMounted` 라이프사이클
- `52-85` : `<template>` — v-if, v-for, @click, @submit 등 디렉티브

**학습 포인트:**
- `<script setup>` 문법 (Composition API 표준)
- `ref()` vs `reactive()` 차이 (ref은 .value, reactive는 직접)
- `onMounted`, `onUnmounted` 등 라이프사이클 훅
- `v-model="noteInput"` 양방향 바인딩
- `:key="n.id"` 가 왜 필수인지 (Vue 가상 DOM diff)

### 4.4 `src/api.js` — axios 인스턴스 (★ 패턴 학습)

**봐야 할 라인 전부 (12줄):**
- `3-6` : axios 인스턴스 생성 (baseURL, timeout)
- `8-11` : API 함수 export (재사용 가능한 함수)

**학습 포인트:**
- baseURL `/api` 사용 → Vite proxy가 처리
- `r.data` 패턴 → axios 응답에서 data만 추출
- 더 좋은 패턴 : 인터셉터로 에러 처리 통일, 토큰 자동 첨부

### 4.5 `vite.config.js` — 개발 서버 (★ proxy 핵심)

**봐야 할 라인:**
- `4-15` : defineConfig
- `7` : `host: '0.0.0.0'` — 외부 접근 가능 (Docker 등)
- `8` : `port: 5173`
- `9-14` : **proxy 설정 (★)** — `/api` 요청을 백엔드로 자동 전달

**학습 포인트:**
- 개발 시 CORS 회피 트릭 (proxy 거치니까 같은 origin)
- `changeOrigin: true` — Host 헤더 변경
- 운영 환경에선 Nginx 등이 같은 역할

---

## 5. 인프라 파일

### 5.1 `docker-compose.yml` (★ 매우 중요)

**서비스 3개:**
- `postgres` (5-19) : PostgreSQL 17 alpine
- `redis` (21-30) : Redis 7 alpine
- `backend` (32-49) : Spring Boot 컨테이너

**봐야 할 라인:**
- `13` : `POSTGRES_PASSWORD: awsstudy` — 운영에선 절대 평문 X
- `15-17` : 호스트 5432 ↔ 컨테이너 5432 매핑
- `18-19` : `volumes` — 데이터 영속화
- `21-30` : healthcheck — 컨테이너 정상 동작 확인
- `40-49` : backend 환경변수 (DB·Redis 연결 정보)
- `51-54` : `volumes` 최상위 선언

**학습 포인트:**
- service 이름 = 컨테이너 간 호스트명 (예: `jdbc:postgresql://postgres:5432`)
- `depends_on.condition: service_healthy` — 헬스체크 통과 후 시작
- 볼륨 = 컨테이너 재시작해도 데이터 유지

### 5.2 `backend/Dockerfile` (★ Multi-stage 빌드)

**봐야 할 라인 전부 (14줄):**
- `2` : Build stage — `gradle:8.10-jdk21-alpine` (빌드 도구 포함)
- `6` : `gradle bootJar --no-daemon` — Spring Boot 실행 JAR 생성
- `9` : Runtime stage — `eclipse-temurin:21-jre-alpine` (JRE만, 더 가벼움)
- `11` : `COPY --from=build` — 이전 스테이지 결과물 복사
- `13` : `MaxRAMPercentage` — 컨테이너 메모리 자동 인식

**학습 포인트:**
- Multi-stage 빌드 = 최종 이미지 작게 (빌드 도구 미포함)
- alpine = 경량 베이스 이미지
- `--no-daemon` 옵션 (CI 환경에서 권장)

---

## 6. 학습 우선순위

### Tier 1 — 무조건 먼저 (1주차)

| 파일 | 이유 | 시간 |
|---|---|---|
| `application.yml` | 부트 설정의 시작점 | 30분 |
| `note/Note.java` | JPA 엔티티 학습 핵심 | 1시간 |
| `note/NoteRepository.java` | JpaRepository 개념 | 30분 |
| `note/NoteController.java` | REST + DI 패턴 | 1시간 |
| `App.vue` | Vue 3 Composition API | 1시간 |
| `api.js` | axios 패턴 | 15분 |
| `vite.config.js` | proxy 핵심 | 15분 |

**총 4~5시간** = 1주차 안에 다 봄

### Tier 2 — 출시 전 (2~4주차)

| 파일 | 이유 |
|---|---|
| `build.gradle` | 의존성 추가할 때 |
| `docker-compose.yml` | 로컬 환경 띄울 때 |
| `WebConfig.java` | CORS 이슈 만났을 때 |
| `Dockerfile` | AWS 배포 직전 |

### Tier 3 — 참고용 (필요할 때)

| 파일 | 이유 |
|---|---|
| `HelloController.java` | 단순 예시 |
| `CounterController.java` | Redis 사용 패턴 (당장 안 씀) |
| `DemoApplication.java` | 진입점 (수정할 일 거의 없음) |
| `AWS_FREETIER_SETUP_GUIDE.md` | AWS 배포 시작할 때 |

---

## 7. 실행 방법

### 7.1 로컬 개발 (가장 흔한 패턴)

```powershell
# 1. DB + Redis만 Docker로 (백엔드는 IDE에서)
cd e:\awsStudy
docker compose up -d postgres redis

# 2. 백엔드 띄우기 (IDE 또는 CLI)
cd backend
.\gradlew bootRun

# 3. 프론트 띄우기 (별도 터미널)
cd e:\awsStudy\frontend
npm install   # 처음만
npm run dev

# 4. 접속
브라우저 → http://localhost:5173
```

### 7.2 전체 Docker compose

```powershell
cd e:\awsStudy
docker compose up -d
# postgres + redis + backend 다 띄움
# 프론트는 호스트에서 npm run dev
```

### 7.3 정지 + 정리

```powershell
docker compose down           # 컨테이너만 정지
docker compose down -v        # 볼륨까지 삭제 (DB 데이터 날아감)
```

### 7.4 헬스체크 확인

```powershell
# 백엔드 헬스
curl http://localhost:8080/actuator/health

# API 호출
curl http://localhost:8080/api/hello
curl http://localhost:8080/api/notes
```

---

## 8. 사이드 시작 시 손볼 곳

기존 demo 코드 그대로 두면 안 되고, 사이드에 맞춰 손봐야 할 부분 :

### 8.1 패키지·앱 이름 변경
- `com.awsstudy.demo` → `com.본인이름.사이드이름`
- `DemoApplication` → `사이드이름Application`
- `spring.application.name: awsstudy-backend` → 본인 이름

### 8.2 도메인 패키지 추가
- `note/` 예시 보고 → 본인 도메인 패키지 추가
- 예: `tracker/`, `expense/`, `manage/` 등
- 각 패키지에 `Entity`, `Repository`, `Service`, `Controller` 추가

### 8.3 Service 레이어 추가 (베스트 프랙티스)
- 현재 : Controller → Repository 직접 호출
- 개선 : Controller → Service → Repository
- `note/NoteService.java` 만들어서 `@Transactional`, 비즈니스 로직 분리

### 8.4 DTO 분리
- 현재 : `Map<String, String>` 또는 엔티티 직접 반환
- 개선 : `CreateNoteRequest`, `NoteResponse` DTO 분리
- 이유 : API 변경이 엔티티에 영향 X, 검증(@Valid) 적용 가능

### 8.5 예외 처리
- 현재 : 없음
- 추가 : `@RestControllerAdvice` 글로벌 예외 처리
- 사용자 친화적 에러 응답 + 로그 분리

### 8.6 환경 분리
- `application.yml` 하나 → `application-local.yml`, `application-prod.yml`
- 로컬은 H2, 운영은 PostgreSQL 같은 분리 가능

### 8.7 PWA 추가 (출시 직전)
- `frontend/public/manifest.json` 추가
- 서비스 워커 등록
- 홈화면 설치 가능

### 8.8 TypeScript 도입 (5~6주차)
- `npm install -D typescript`
- 새 컴포넌트만 `.vue` with `<script setup lang="ts">`
- 기존 JS는 안 건드림 (점진 마이그레이션)

---

## 9. 부트 30% 지식 — 이 프로젝트로 다 학습 가능

학습 플랜에 적힌 부트 핵심 5개 체크리스트 :

- [ ] **@Transactional 전파 + 롤백** → Service 레이어 추가하면서 학습
- [ ] **JPA 영속성 컨텍스트 + N+1** → Note 엔티티 + 관계 매핑 추가하면서
- [ ] **DI 컨테이너 + 빈 생명주기** → `@RequiredArgsConstructor` 생성자 주입
- [ ] **예외 처리 (@ControllerAdvice)** → 글로벌 예외 핸들러 추가하면서
- [ ] **환경별 설정 (application-{profile}.yml)** → 환경 분리하면서

→ 모두 awsStudy 베이스에 자연스럽게 추가하면서 학습 가능.

---

## 한 줄 요약

> **awsStudy = Gradle + JPA + Lombok + Vue 3 + Docker + AWS 가이드 완비된 PoC.**
> **Tier 1 파일 7개 (4~5시간) 먼저 학습 → Tier 2 (2~4주차) → Tier 3 (필요할 때).**
> **사이드 시작 = 패키지 이름 변경 + 도메인 패키지 추가 + Service 레이어 추가부터.**
