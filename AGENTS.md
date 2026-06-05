# AGENTS.md — jgo AI 개발 에이전트 가이드

## 프로젝트 개요

`jgo`는 OpenAI 호환 API를 노출하는 상주형 Go 서버로, `codex` CLI를 통해 자연어 요청을 실행 가능한 자동화 작업으로 변환한다.

- **언어**: Go 1.22 (`main.go` 단일 파일)
- **모듈**: `jgo` (go.mod)
- **컨테이너**: Ubuntu 24.04 기반 (`Dockerfile`)
- **빌드**: `make docker-push` (multi-arch: linux/amd64, linux/arm64)

## 핵심 규칙 (반드시 준수)

### 1. SPEC은 FROZEN 상태
- [SPEC/SPEC.md](SPEC/SPEC.md)가 동작/목적/인터페이스의 궁극적 기준이다.
- SPEC에 정의된 동작을 변경하려면 **반드시 사용자 승인** 후 버전 업데이트와 changelog 추가를 동시에 수행한다.

### 2. 단일 파일 구조 유지
- 모든 핵심 로직은 `main.go` 한 파일에 유지한다.
- 불필요한 추상화, 패키지 분리를 하지 않는다.

### 3. Codex-only 실행 모델
- `jgo`는 절대로 직접 `git`, `gh`, `aws`, `kubectl` 등 도메인 CLI를 사용자 작업으로 실행하지 않는다.
- 모든 작업은 `codex exec --full-auto --skip-git-repo-check "<prompt>"` 단일 호출로 위임한다.

### 4. Git 안전 규칙
- `--force-push`, `--amend`, `reset` 금지.
- Conventional Commits 형식 사용.

## 아키텍처

```
Client → /v1/chat/completions → jgo (main.go)
                                   ├─ 프롬프트 최적화 (선택, OpenAI API 호출)
                                   └─ codex exec (local 또는 SSH)
                                        └─ gh, aws, kubectl, git 등 CLI 활용
```

### 서브커맨드
- `jgo serve` — 상주 API 서버 (기본 `:8080`)
- `jgo exec` — CLI 직접 실행 모드

### API 엔드포인트
| 엔드포인트 | 메서드 | 설명 |
|-----------|--------|------|
| `/healthz` | GET | 헬스체크 |
| `/v1/models` | GET | 모델 목록 (고정: `jgo`) |
| `/v1/chat/completions` | POST | 챗 완성 (stream 지원) |
| `/api/runs` | GET | 실행 이력 조회 |

## 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `JGO_LISTEN_ADDR` | `:8080` | 서버 리슨 주소 |
| `JGO_EXEC_TRANSPORT` | `local` | 실행 방식 (`local` / `ssh`) |
| `JGO_SSH_USER` | `jgo` | SSH 사용자 |
| `JGO_SSH_HOST` | `localhost` | SSH 호스트 |
| `JGO_SSH_PORT` | `22` | SSH 포트 |
| `JGO_OPTIMIZE_PROMPT` | `false` | 프롬프트 최적화 활성화 |
| `OPENAI_API_KEY` | - | OpenAI API 키 (최적화 시 필수) |
| `MODEL` | - | 최적화 모델 (fallback: `OPENWEBUI_MODEL`, `LITELLM_MODEL`) |
| `CODEX_BIN` | `codex` | codex 바이너리 경로 |
| `CODEX_REASONING_EFFORT` | `xhigh` | codex 추론 강도 |

## 파일 구조 & 역할

```
main.go                     # 전체 로직 (API 서버 + CLI + 자동화 오케스트레이션)
Dockerfile                  # 단일 런타임/실행 이미지
docker-entrypoint.sh        # 컨테이너 진입점 (.jgo-cache 준비 → go run main.go)
Makefile                    # 빌드/배포/스크립트 타겟
deploy.sh                   # 배포 스크립트
monitor/                    # 채팅 모니터 웹 UI (index.html, app.js, styles.css)
homefiles/                  # 컨테이너 홈 디렉터리 초기화 파일
scripts/
  jgo-smoke-test.sh         # API 스모크 테스트
  jgo-codex-auth-test.sh    # codex 인증/실행 검증
  deploy-check-verify.sh    # 배포 확인
  ghost-self-growth-loop.sh # 자율 성장 루프
  ghost-autonomous-dev-loop.sh # 자율 개발 루프
  codex-git-push.sh         # codex git push 헬퍼
SPEC/
  SPEC.md                   # 동작 명세 (FROZEN)
  DEVELOPMENT_RULES.md      # 개발 규칙
```

## 코딩 컨벤션

- Go 표준 라이브러리만 사용 (외부 의존성 없음).
- 에러는 `fmt.Errorf`로 래핑하여 반환, `log.Fatal` 대신 `os.Exit(1)` 사용.
- HTTP 핸들러는 `http.NewServeMux` + `HandleFunc` 패턴.
- JSON 응답은 `writeJSON` 헬퍼, 에러 응답은 `writeOpenAIError` 헬퍼 사용.
- 모든 요청에 `run_id` 생성 및 `X-JGO-Run-ID` 헤더 포함.
- stderr에 구조적 로그 출력.

## Makefile 주요 타겟

```bash
make docker-push          # 멀티아키 이미지 빌드 & 푸시
make docker-push-arm64    # ARM64 전용 빌드
make serve                # 로컬 서버 실행
make run-full PROMPT="..."# CLI 직접 실행
make smoke-test           # API 스모크 테스트
make codex-auth-test      # codex 인증 테스트
make verify               # smoke-test + codex-auth-test
make ghost-grow           # 자율 성장 루프 (dry-run)
make autonomous-loop PROMPT="..." # 자율 개발 루프
```

## 테스트 & 검증

- 단위 테스트: 현재 없음 (MVP 단계).
- 통합 검증: `make verify` (`smoke-test` + `codex-auth-test`).
- 스모크 테스트는 Kubernetes `port-forward`를 통해 실행.
- `SMOKE_TEST_BASE_URL` 로 직접 URL 지정 가능.

## AI 에이전트 작업 시 주의사항

1. **SPEC.md를 먼저 읽어라** — 목적, 인터페이스, 불변 조건이 모두 정의되어 있다.
2. **main.go 단일 파일 유지** — 파일을 분리하지 마라.
3. **codex exec만 사용** — jgo가 직접 CLI를 실행하는 코드를 추가하지 마라.
4. **외부 의존성 추가 금지** — Go 표준 라이브러리만 사용.
5. **force-push / amend 금지** — Git 안전 규칙 준수.
6. **프롬프트 최적화는 기본 OFF** — 명시적 활성화 없이 자동으로 켜지 않아야 한다.
7. **응답은 raw codex 출력만** — 래퍼, 접두어, 폴백 JSON을 추가하지 마라.
8. **Kubernetes 배포 기본값**: namespace=`ai`, workload=`jgo`, port=`8080`.
