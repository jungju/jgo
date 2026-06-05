# CLAUDE.md — jgo 프로젝트 컨텍스트

이 파일은 Claude (claude-code, claude-sonnet 등)가 프로젝트를 이해하고 작업할 때 참조하는 가이드다.

## 프로젝트 요약

`jgo`는 OpenAI 호환 API를 노출하는 상주형 Go 서버이다. 자연어 요청을 받아 `codex` CLI를 통해 실행한다.

- **Go 1.22**, 단일 파일 (`main.go`), 표준 라이브러리만 사용
- 서버 모드 (`jgo serve`) + CLI 모드 (`jgo exec`)
- 실행 위임: `codex exec --full-auto --skip-git-repo-check`

## 빌드 & 실행

```bash
# 로컬 서버 실행
go run main.go serve

# CLI 직접 실행
go run main.go exec --env-file .env "작업 지시"

# 컨테이너 빌드 & 푸시
make docker-push

# 전체 검증
make verify
```

## 절대 규칙

1. `SPEC/SPEC.md`는 **FROZEN** — 명시적 사용자 승인 없이 변경 불가
2. `main.go` 단일 파일 유지 — 패키지 분리 금지
3. 외부 Go 의존성 추가 금지 — 표준 라이브러리만 사용
4. jgo가 직접 `git`/`gh`/`aws`/`kubectl` 실행 금지 — codex 위임만 허용
5. `force-push` / `amend` / `reset` 금지
6. Conventional Commits 형식 사용

## 코드 패턴

```go
// 에러 래핑
fmt.Errorf("context: %w", err)

// HTTP 핸들러
mux := http.NewServeMux()
mux.HandleFunc("/path", func(w http.ResponseWriter, r *http.Request) { ... })

// JSON 응답
writeJSON(w, http.StatusOK, data)
writeOpenAIError(w, http.StatusBadRequest, "message")

// 요청별 run_id
runID := nextRunID()
ctx := context.WithValue(r.Context(), runIDContextKey{}, runID)
w.Header().Set("X-JGO-Run-ID", runID)

// 구조적 로깅
logRunf(ctx, "message: key=%v", value)
```

## 핵심 파일

| 파일 | 역할 |
|------|------|
| `main.go` | 전체 서버/CLI/자동화 로직 |
| `SPEC/SPEC.md` | 동작 명세 (FROZEN — 반드시 먼저 읽을 것) |
| `SPEC/DEVELOPMENT_RULES.md` | 개발 제약 사항 |
| `Makefile` | 빌드/배포/테스트 타겟 |
| `Dockerfile` | 단일 런타임 이미지 |
| `docker-entrypoint.sh` | 컨테이너 시작 스크립트 |
| `monitor/` | 채팅 모니터 웹 UI |
| `scripts/` | 배포/검증 스크립트 |

## 환경변수 (주요)

- `JGO_LISTEN_ADDR` (`:8080`) — 서버 주소
- `JGO_EXEC_TRANSPORT` (`local`) — 실행 방식 (`local`/`ssh`)
- `JGO_OPTIMIZE_PROMPT` (`false`) — 프롬프트 최적화
- `CODEX_BIN` (`codex`) — codex 경로
- `CODEX_REASONING_EFFORT` (`xhigh`) — 추론 강도
- `OPENAI_API_KEY`, `MODEL` — 최적화 시 필수

## 테스트

- 단위 테스트 없음 (MVP)
- `make verify` = `make smoke-test` + `make codex-auth-test`
- Kubernetes: namespace=`ai`, workload=`jgo`, port=`8080`

## 작업 전 체크리스트

1. `SPEC/SPEC.md` 읽기
2. `SPEC/DEVELOPMENT_RULES.md` 읽기
3. `main.go` 구조 파악
4. 변경이 SPEC과 충돌하지 않는지 확인
