package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const (
	defaultListenAddr = ":8080"
	defaultOpenAIBase = "https://api.openai.com/v1"
	servedModelID     = "jgo"
)

var errCodexLoginRequired = errors.New("codex login is required")

var runCounter atomic.Uint64

type Config struct {
	CodexBin                 string
	ListenAddr               string
	SSHUser                  string
	SSHHost                  string
	SSHPort                  string
	SSHKeyPath               string
	SSHStrictHostKeyChecking bool
	OptimizePrompt           bool
}

type OpenAIConfig struct {
	BaseURL string
	APIKey  string
	Model   string
}

type RequestPlan struct {
	OptimizedPrompt string `json:"optimized_prompt"`
}

type AutomationResult struct {
	Branch        string
	CodexResponse string
}

type plannerChatRequest struct {
	Model          string         `json:"model"`
	Temperature    float64        `json:"temperature"`
	ResponseFormat responseFormat `json:"response_format"`
	Messages       []chatMessage  `json:"messages"`
}

type responseFormat struct {
	Type string `json:"type"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type plannerChatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

type openAIChatCompletionRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
	Stream   bool          `json:"stream,omitempty"`
}

type openAIChatCompletionResponse struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	Model   string `json:"model"`
	Choices []struct {
		Index        int         `json:"index"`
		Message      chatMessage `json:"message"`
		FinishReason string      `json:"finish_reason"`
	} `json:"choices"`
	Usage openAIUsage `json:"usage"`
}

type openAIChatCompletionChunkResponse struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	Model   string `json:"model"`
	Choices []struct {
		Index        int              `json:"index"`
		Delta        chatMessageDelta `json:"delta"`
		FinishReason *string          `json:"finish_reason"`
	} `json:"choices"`
}

type chatMessageDelta struct {
	Role    string `json:"role,omitempty"`
	Content string `json:"content,omitempty"`
}

type openAIUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type openAIErrorResponse struct {
	Error openAIErrorBody `json:"error"`
}

type openAIErrorBody struct {
	Message string `json:"message"`
	Type    string `json:"type"`
}

type openAIModelsResponse struct {
	Object string        `json:"object"`
	Data   []openAIModel `json:"data"`
}

type openAIModel struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	OwnedBy string `json:"owned_by"`
}

type runIDContextKey struct{}

func main() {
	cfg, err := loadConfigFromEnv()
	if err != nil {
		log.Printf("error: %v", err)
		os.Exit(1)
	}

	if len(os.Args) < 2 {
		if err := serveCommand(cfg, nil); err != nil {
			log.Printf("error: %v", err)
			os.Exit(1)
		}
		return
	}

	switch os.Args[1] {
	case "serve":
		if err := serveCommand(cfg, os.Args[2:]); err != nil {
			log.Printf("error: %v", err)
			os.Exit(1)
		}
	case "run":
		if err := runCommand(cfg, os.Args[2:]); err != nil {
			log.Printf("error: %v", err)
			os.Exit(1)
		}
	case "exec":
		if err := execCommand(cfg, os.Args[2:]); err != nil {
			log.Printf("error: %v", err)
			os.Exit(1)
		}
	default:
		printStartupError(fmt.Sprintf("unknown subcommand: %s", os.Args[1]), os.Args[1:])
		printUsage()
		os.Exit(2)
	}
}

func serveCommand(cfg Config, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	listen := fs.String("listen", cfg.ListenAddr, "listen address")
	optimizePrompt := fs.Bool("optimize-prompt", cfg.OptimizePrompt, "enable prompt optimization before codex execution")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse serve args: %w", err)
	}

	cfg.ListenAddr = strings.TrimSpace(*listen)
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = defaultListenAddr
	}
	cfg.OptimizePrompt = *optimizePrompt
	if err := validateSSHConfig(&cfg); err != nil {
		return err
	}

	return runServer(cfg)
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  jgo serve [--optimize-prompt]")
	fmt.Fprintln(os.Stderr, "  jgo run [--env-file .env] \"<instruction>\"")
	fmt.Fprintln(os.Stderr, "  jgo exec [--env-file .env] [--optimize-prompt] \"<instruction>\"")
	fmt.Fprintln(os.Stderr, "default: jgo serve")
}

func runCommand(cfg Config, args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	envFile := fs.String("env-file", ".env", "path to env file")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse run args: %w", err)
	}
	if fs.NArg() == 0 {
		return fmt.Errorf("missing instruction argument")
	}

	instruction := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if instruction == "" {
		return fmt.Errorf("instruction cannot be empty")
	}

	if path := strings.TrimSpace(*envFile); path != "" {
		if err := loadEnvFile(path); err != nil {
			return fmt.Errorf("load env file (%s): %w", path, err)
		}
	}
	reloadedCfg, err := loadConfigFromEnv()
	if err != nil {
		return err
	}
	cfg = reloadedCfg
	if err := validateSSHConfig(&cfg); err != nil {
		return err
	}

	runID := nextRunID()
	ctx := context.WithValue(context.Background(), runIDContextKey{}, runID)
	logRunf(ctx, "cli run start: mode=prompt_optimize_only env_file=%q", strings.TrimSpace(*envFile))
	return runPromptOptimizeOnly(ctx, cfg, instruction)
}

func execCommand(cfg Config, args []string) error {
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	envFile := fs.String("env-file", ".env", "path to env file")
	optimizePrompt := fs.Bool("optimize-prompt", cfg.OptimizePrompt, "enable prompt optimization before codex execution")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse exec args: %w", err)
	}
	if fs.NArg() == 0 {
		return fmt.Errorf("missing instruction argument")
	}

	instruction := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if instruction == "" {
		return fmt.Errorf("instruction cannot be empty")
	}

	if path := strings.TrimSpace(*envFile); path != "" {
		if err := loadEnvFile(path); err != nil {
			return fmt.Errorf("load env file (%s): %w", path, err)
		}
	}
	reloadedCfg, err := loadConfigFromEnv()
	if err != nil {
		return err
	}
	cfg = reloadedCfg
	cfg.OptimizePrompt = *optimizePrompt
	if err := validateSSHConfig(&cfg); err != nil {
		return err
	}

	runID := nextRunID()
	ctx := context.WithValue(context.Background(), runIDContextKey{}, runID)
	logRunf(
		ctx,
		"cli exec start: mode=full_automation env_file=%q optimize_prompt=%t",
		strings.TrimSpace(*envFile),
		cfg.OptimizePrompt,
	)

	result, err := runAutomation(ctx, cfg, instruction)
	if err != nil {
		return err
	}

	out := map[string]string{
		"status": "ok",
		"branch": result.Branch,
	}
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		return fmt.Errorf("print exec output: %w", err)
	}
	return nil
}

func printStartupError(reason string, args []string) {
	argv := append([]string{os.Args[0]}, args...)
	fmt.Fprintln(os.Stderr, "error:", reason)
	fmt.Fprintf(os.Stderr, "detail: argv=%q\n", argv)
}

func loadConfigFromEnv() (Config, error) {
	optimizePrompt, err := parseBoolEnvDefault("JGO_OPTIMIZE_PROMPT", false)
	if err != nil {
		return Config{}, err
	}
	sshStrictHostKeyChecking, err := parseBoolEnvDefault("JGO_SSH_STRICT_HOST_KEY_CHECKING", false)
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		CodexBin:                 strings.TrimSpace(os.Getenv("CODEX_BIN")),
		ListenAddr:               strings.TrimSpace(os.Getenv("JGO_LISTEN_ADDR")),
		SSHUser:                  strings.TrimSpace(os.Getenv("JGO_SSH_USER")),
		SSHHost:                  strings.TrimSpace(os.Getenv("JGO_SSH_HOST")),
		SSHPort:                  strings.TrimSpace(os.Getenv("JGO_SSH_PORT")),
		SSHStrictHostKeyChecking: sshStrictHostKeyChecking,
		OptimizePrompt:           optimizePrompt,
	}

	if cfg.CodexBin == "" {
		cfg.CodexBin = "codex"
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = defaultListenAddr
	}

	return cfg, nil
}

func validateSSHConfig(cfg *Config) error {
	var missing []string
	if strings.TrimSpace(cfg.SSHUser) == "" {
		missing = append(missing, "JGO_SSH_USER")
	}
	if strings.TrimSpace(cfg.SSHHost) == "" {
		missing = append(missing, "JGO_SSH_HOST")
	}
	if strings.TrimSpace(cfg.SSHPort) == "" {
		missing = append(missing, "JGO_SSH_PORT")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required SSH settings: %s", strings.Join(missing, ", "))
	}
	return nil
}

func parseBoolEnvDefault(key string, defaultVal bool) (bool, error) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return defaultVal, nil
	}
	v, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("invalid boolean for %s: %q", key, raw)
	}
	return v, nil
}

func runServer(cfg Config) error {
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	chatHandler := handleChatCompletions(cfg)
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeMethodNotAllowed(w, http.MethodPost)
			return
		}
		chatHandler(w, r)
	})

	modelsHandler := handleModels()
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeMethodNotAllowed(w, http.MethodGet)
			return
		}
		modelsHandler(w, r)
	})

	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("jgo server listening on %s", cfg.ListenAddr)
	return server.ListenAndServe()
}

func handleChatCompletions(cfg Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		runID := nextRunID()
		ctx := context.WithValue(r.Context(), runIDContextKey{}, runID)
		w.Header().Set("X-JGO-Run-ID", runID)

		var req openAIChatCompletionRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			logRunf(ctx, "request rejected: invalid JSON body: %v", err)
			writeOpenAIError(w, http.StatusBadRequest, fmt.Sprintf("invalid JSON body: %s (run_id=%s)", err.Error(), runID))
			return
		}

		logRunf(
			ctx,
			"incoming chat request: path=%s method=%s model=%q stream=%t messages=%d remote=%s",
			r.URL.Path,
			r.Method,
			strings.TrimSpace(req.Model),
			req.Stream,
			len(req.Messages),
			r.RemoteAddr,
		)

		instruction := extractInstructionFromMessages(req.Messages)
		if instruction == "" {
			logRunf(ctx, "request rejected: missing user instruction in messages")
			writeOpenAIError(w, http.StatusBadRequest, fmt.Sprintf("missing user instruction in messages (run_id=%s)", runID))
			return
		}
		logRunf(ctx, "instruction preview=%q", truncateForLog(instruction, 160))

		result, err := runAutomation(ctx, cfg, instruction)
		if err != nil {
			if errors.Is(err, errCodexLoginRequired) {
				msg := "codex가 로그인되어 있지 않습니다. 먼저 `codex login`을 실행한 뒤 다시 요청하세요."
				logRunf(ctx, "automation blocked detail: %v", err)
				logRunf(ctx, "automation blocked: %s", msg)
				if req.Stream {
					if streamErr := writeStreamingChatCompletion(w, servedModelID, msg); streamErr != nil {
						logRunf(ctx, "stream write failed: %v", streamErr)
					}
					return
				}
				writeJSON(w, http.StatusOK, buildAssistantChatCompletion(servedModelID, msg))
				return
			}
			logRunf(ctx, "automation failed: %v", err)
			writeOpenAIError(w, http.StatusBadRequest, fmt.Sprintf("%s (run_id=%s)", err.Error(), runID))
			return
		}

		model := strings.TrimSpace(req.Model)
		if model == "" {
			model = servedModelID
		}
		if model != servedModelID {
			logRunf(ctx, "request rejected: unsupported model=%q", model)
			writeOpenAIError(
				w,
				http.StatusBadRequest,
				fmt.Sprintf("unsupported model %q; use %q (run_id=%s)", model, servedModelID, runID),
			)
			return
		}

		content := strings.TrimSpace(result.CodexResponse)
		if content == "" {
			content = fmt.Sprintf(`{"status":"ok","branch":"%s"}`, result.Branch)
		} else if result.Branch != "" {
			content = content + "\n\n[branch] " + result.Branch
		}
		if req.Stream {
			if err := writeStreamingChatCompletion(w, servedModelID, content); err != nil {
				logRunf(ctx, "stream write failed: %v", err)
			}
			logRunf(ctx, "request completed: stream=true branch=%s content_len=%d", result.Branch, len(content))
			return
		}

		resp := buildAssistantChatCompletion(servedModelID, content)
		writeJSON(w, http.StatusOK, resp)
		logRunf(ctx, "request completed: stream=false branch=%s content_len=%d", result.Branch, len(content))
	}
}

func buildAssistantChatCompletion(model, content string) openAIChatCompletionResponse {
	resp := openAIChatCompletionResponse{
		ID:      "chatcmpl-" + time.Now().UTC().Format("20060102150405"),
		Object:  "chat.completion",
		Created: time.Now().Unix(),
		Model:   model,
		Usage: openAIUsage{
			PromptTokens:     0,
			CompletionTokens: 0,
			TotalTokens:      0,
		},
	}
	resp.Choices = []struct {
		Index        int         `json:"index"`
		Message      chatMessage `json:"message"`
		FinishReason string      `json:"finish_reason"`
	}{
		{
			Index:        0,
			Message:      chatMessage{Role: "assistant", Content: content},
			FinishReason: "stop",
		},
	}
	return resp
}

func writeStreamingChatCompletion(w http.ResponseWriter, model, content string) error {
	flusher, ok := w.(http.Flusher)
	if !ok {
		return fmt.Errorf("streaming is not supported by this server")
	}

	now := time.Now()
	chatID := "chatcmpl-" + now.UTC().Format("20060102150405")
	created := now.Unix()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	if err := writeSSEChunk(w, flusher, chatID, created, model, chatMessageDelta{Role: "assistant"}, nil); err != nil {
		return err
	}
	if err := writeSSEChunk(w, flusher, chatID, created, model, chatMessageDelta{Content: content}, nil); err != nil {
		return err
	}
	finishReason := "stop"
	if err := writeSSEChunk(w, flusher, chatID, created, model, chatMessageDelta{}, &finishReason); err != nil {
		return err
	}

	if _, err := fmt.Fprint(w, "data: [DONE]\n\n"); err != nil {
		return err
	}
	flusher.Flush()
	return nil
}

func writeSSEChunk(w http.ResponseWriter, flusher http.Flusher, chatID string, created int64, model string, delta chatMessageDelta, finishReason *string) error {
	chunk := openAIChatCompletionChunkResponse{
		ID:      chatID,
		Object:  "chat.completion.chunk",
		Created: created,
		Model:   model,
	}
	chunk.Choices = []struct {
		Index        int              `json:"index"`
		Delta        chatMessageDelta `json:"delta"`
		FinishReason *string          `json:"finish_reason"`
	}{
		{
			Index:        0,
			Delta:        delta,
			FinishReason: finishReason,
		},
	}

	payload, err := json.Marshal(chunk)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "data: %s\n\n", payload); err != nil {
		return err
	}
	flusher.Flush()
	return nil
}

func handleModels() http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		resp := openAIModelsResponse{
			Object: "list",
			Data: []openAIModel{
				{
					ID:      servedModelID,
					Object:  "model",
					Created: 0,
					OwnedBy: "jgo",
				},
			},
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

func writeMethodNotAllowed(w http.ResponseWriter, allowMethod string) {
	w.Header().Set("Allow", allowMethod)
	writeJSON(w, http.StatusMethodNotAllowed, map[string]string{
		"error": "method not allowed",
	})
}

func extractInstructionFromMessages(messages []chatMessage) string {
	for i := len(messages) - 1; i >= 0; i-- {
		if strings.EqualFold(strings.TrimSpace(messages[i].Role), "user") {
			content := strings.TrimSpace(messages[i].Content)
			if content != "" {
				return content
			}
		}
	}
	return ""
}

func writeOpenAIError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, openAIErrorResponse{
		Error: openAIErrorBody{
			Message: message,
			Type:    "invalid_request_error",
		},
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("write json response failed: %v", err)
	}
}

func nextRunID() string {
	n := runCounter.Add(1)
	return fmt.Sprintf("run-%s-%06d", time.Now().UTC().Format("20060102T150405.000"), n)
}

func logRunf(ctx context.Context, format string, args ...any) {
	runID, _ := ctx.Value(runIDContextKey{}).(string)
	if runID == "" {
		log.Printf(format, args...)
		return
	}
	log.Printf("[run_id=%s] %s", runID, fmt.Sprintf(format, args...))
}

func truncateForLog(s string, max int) string {
	if max <= 0 {
		return ""
	}
	trimmed := strings.TrimSpace(s)
	if len(trimmed) <= max {
		return trimmed
	}
	return trimmed[:max] + "...(truncated)"
}

func logCommandOutput(ctx context.Context, label string, out []byte) {
	output := strings.TrimSpace(string(out))
	if output == "" {
		logRunf(ctx, "%s output=<empty>", label)
		return
	}
	logRunf(ctx, "%s output=%q", label, truncateForLog(output, 1200))
}

func sanitizeURL(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u == nil {
		return strings.TrimSpace(raw)
	}
	u.User = nil
	u.RawQuery = ""
	u.Fragment = ""
	return u.String()
}

func runAutomation(ctx context.Context, cfg Config, instruction string) (AutomationResult, error) {
	logRunf(ctx, "automation start")
	if err := validateSSHConfig(&cfg); err != nil {
		return AutomationResult{}, err
	}
	envMap := environToMap(os.Environ())
	applyProviderFallbacks(envMap)
	availableCLIs := resolveAvailableCLIs(envMap, cfg.CodexBin)
	logRunf(ctx, "available_clis=%s", strings.Join(availableCLIs, ", "))
	logRunf(ctx, "prompt_optimize_enabled=%t", cfg.OptimizePrompt)

	optimizedPrompt := strings.TrimSpace(instruction)
	if cfg.OptimizePrompt {
		openaiCfg, err := loadOpenAIConfig(envMap)
		if err != nil {
			return AutomationResult{}, err
		}
		logRunf(
			ctx,
			"openai config loaded: base_url=%s model=%s api_key_set=%t",
			sanitizeURL(openaiCfg.BaseURL),
			openaiCfg.Model,
			strings.TrimSpace(openaiCfg.APIKey) != "",
		)

		logRunf(ctx, "stage=prompt_optimize start")
		plan, err := analyzeRequest(ctx, openaiCfg, instruction, availableCLIs)
		if err != nil {
			return AutomationResult{}, fmt.Errorf("prompt optimize: %w", err)
		}
		if strings.TrimSpace(plan.OptimizedPrompt) != "" {
			optimizedPrompt = strings.TrimSpace(plan.OptimizedPrompt)
		}
		logRunf(ctx, "stage=prompt_optimize done: optimized_prompt_len=%d", len(optimizedPrompt))
	} else {
		logRunf(ctx, "stage=prompt_optimize skipped: enabled=false")
	}

	repoRef := ""
	repoURL := ""
	repoScoped := false
	if ref, refErr := extractRepoRef(instruction); refErr == nil {
		repoRef = ref
		var err error
		repoURL, err = repoURLFromRepoRef(repoRef)
		if err != nil {
			return AutomationResult{}, err
		}
		repoScoped = true
		logRunf(ctx, "repo resolved: ref=%q url=%s", repoRef, sanitizeURL(repoURL))
	} else {
		logRunf(ctx, "repo context not found; running workspace-only task")
	}

	logRunf(ctx, "repo_scope: repo_scoped=%t repo_ref=%q", repoScoped, repoRef)

	if _, err := exec.LookPath("ssh"); err != nil {
		return AutomationResult{}, fmt.Errorf("ssh is required in PATH: %w", err)
	}
	logRunf(ctx, "transport binary found: ssh (target=%s)", formatSSHAddress(cfg))

	codexEnv := mapToEnviron(envMap)
	logRunf(ctx, "stage=codex_login_check start")
	if err := ensureCodexLogin(ctx, cfg, codexEnv); err != nil {
		return AutomationResult{}, err
	}
	logRunf(ctx, "stage=codex_login_check done")

	logRunf(ctx, "stage=remote_workdir_prepare start")
	remoteWorkDir, err := createRemoteWorkDir(ctx, cfg, codexEnv)
	if err != nil {
		return AutomationResult{}, err
	}
	logRunf(ctx, "stage=remote_workdir_prepare done: remote_dir=%s", remoteWorkDir)
	defer cleanupRemoteWorkDir(ctx, cfg, codexEnv, remoteWorkDir)

	branch := fmt.Sprintf("jgo/%s", time.Now().UTC().Format("20060102-150405"))
	codexResponses := make([]string, 0, 2)

	logRunf(ctx, "stage=codex_edit start")
	editPrompt := buildWorkspacePrompt(optimizedPrompt, availableCLIs)
	if repoScoped {
		editPrompt = buildEditPrompt(repoRef, repoURL, branch, optimizedPrompt, availableCLIs)
	}
	editResp, err := runCodexExec(ctx, cfg, remoteWorkDir, codexEnv, editPrompt)
	if err != nil {
		return AutomationResult{}, fmt.Errorf("codex edit failed: %w", err)
	}
	if s := strings.TrimSpace(editResp); s != "" {
		codexResponses = append(codexResponses, "[codex_edit]\n"+s)
	}
	logRunf(ctx, "stage=codex_edit done")

	if !repoScoped {
		logRunf(ctx, "stage=codex_commit_push skipped: repository context not provided")
		logRunf(ctx, "automation success: branch=")
		return AutomationResult{
			Branch:        "",
			CodexResponse: strings.Join(codexResponses, "\n\n"),
		}, nil
	}

	logRunf(ctx, "stage=codex_commit_push start")
	commitResp, err := runCodexExec(ctx, cfg, remoteWorkDir, codexEnv, buildCommitPushPrompt(repoRef, repoURL, branch))
	if err != nil {
		return AutomationResult{}, fmt.Errorf("codex commit/push failed: %w", err)
	}
	if s := strings.TrimSpace(commitResp); s != "" {
		codexResponses = append(codexResponses, "[codex_commit_push]\n"+s)
	}
	logRunf(ctx, "stage=codex_commit_push done")
	logRunf(ctx, "automation success: branch=%s", branch)

	return AutomationResult{
		Branch:        branch,
		CodexResponse: strings.Join(codexResponses, "\n\n"),
	}, nil
}

func runPromptOptimizeOnly(ctx context.Context, cfg Config, instruction string) error {
	envMap := environToMap(os.Environ())
	applyProviderFallbacks(envMap)

	openaiCfg, err := loadOpenAIConfig(envMap)
	if err != nil {
		return err
	}
	availableCLIs := resolveAvailableCLIs(envMap, cfg.CodexBin)

	logRunf(
		ctx,
		"prompt_optimize_only: base_url=%s model=%s available_clis=%s",
		sanitizeURL(openaiCfg.BaseURL),
		openaiCfg.Model,
		strings.Join(availableCLIs, ", "),
	)

	plan, err := analyzeRequest(ctx, openaiCfg, instruction, availableCLIs)
	if err != nil {
		return fmt.Errorf("prompt optimize: %w", err)
	}
	if _, err := fmt.Fprintln(os.Stdout, plan.OptimizedPrompt); err != nil {
		return fmt.Errorf("print optimized prompt: %w", err)
	}
	return nil
}

func loadOpenAIConfig(env map[string]string) (OpenAIConfig, error) {
	cfg := OpenAIConfig{
		BaseURL: strings.TrimSpace(env["OPENAI_BASE_URL"]),
		APIKey:  strings.TrimSpace(env["OPENAI_API_KEY"]),
		Model:   strings.TrimSpace(env["MODEL"]),
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultOpenAIBase
	}

	var missing []string
	if cfg.APIKey == "" {
		missing = append(missing, "OPENAI_API_KEY")
	}
	if cfg.Model == "" {
		missing = append(missing, "MODEL")
	}
	if len(missing) > 0 {
		return OpenAIConfig{}, fmt.Errorf("missing required OpenAI settings: %s", strings.Join(missing, ", "))
	}

	return cfg, nil
}

func analyzeRequest(ctx context.Context, cfg OpenAIConfig, instruction string, availableCLIs []string) (RequestPlan, error) {
	cliList := strings.Join(availableCLIs, ", ")
	if strings.TrimSpace(cliList) == "" {
		cliList = "codex, git"
	}

	reqBody := plannerChatRequest{
		Model:          cfg.Model,
		Temperature:    1,
		ResponseFormat: responseFormat{Type: "json_object"},
		Messages: []chatMessage{
			{
				Role:    "system",
				Content: fmt.Sprintf("Return strict JSON only with key: optimized_prompt(string). Do not include any other keys or text. Your job is prompt optimization only, not execution decision. Rewrite the user request into a clear, concrete Codex execution prompt. Available CLI tools from environment: %s. Prefer these CLIs in optimized_prompt. For GitHub tasks, use gh when available. For Kubernetes tasks, use kubectl when available.", cliList),
			},
			{
				Role:    "user",
				Content: instruction,
			},
		},
	}

	payload, err := json.Marshal(reqBody)
	if err != nil {
		return RequestPlan{}, err
	}

	endpoint := strings.TrimRight(cfg.BaseURL, "/") + "/chat/completions"
	logRunf(
		ctx,
		"stage=prompt_optimize call_openai: endpoint=%s model=%s instruction_len=%d",
		sanitizeURL(endpoint),
		cfg.Model,
		len(instruction),
	)
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return RequestPlan{}, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return RequestPlan{}, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return RequestPlan{}, err
	}
	logRunf(
		ctx,
		"stage=prompt_optimize openai_response: status=%s body_preview=%q",
		resp.Status,
		truncateForLog(strings.TrimSpace(string(respBody)), 400),
	)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return RequestPlan{}, fmt.Errorf(
			"request failed (endpoint=%s, status=%s): %s",
			sanitizeURL(endpoint),
			resp.Status,
			strings.TrimSpace(string(respBody)),
		)
	}

	var chatResp plannerChatResponse
	if err := json.Unmarshal(respBody, &chatResp); err != nil {
		return RequestPlan{}, fmt.Errorf("decode chat response: %w", err)
	}
	if len(chatResp.Choices) == 0 {
		return RequestPlan{}, fmt.Errorf("chat response has no choices")
	}

	content := strings.TrimSpace(chatResp.Choices[0].Message.Content)
	if content == "" {
		return RequestPlan{}, fmt.Errorf("chat response content is empty")
	}

	return parseRequestPlan(content)
}

func parseRequestPlan(raw string) (RequestPlan, error) {
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.DisallowUnknownFields()

	var plan RequestPlan
	if err := dec.Decode(&plan); err != nil {
		return RequestPlan{}, fmt.Errorf("parse plan json: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return RequestPlan{}, fmt.Errorf("parse plan json: trailing data")
	}

	plan.OptimizedPrompt = strings.TrimSpace(plan.OptimizedPrompt)
	if plan.OptimizedPrompt == "" {
		return RequestPlan{}, fmt.Errorf("parse plan json: optimized_prompt is required")
	}

	return plan, nil
}

func ensureCodexLogin(ctx context.Context, cfg Config, codexEnv []string) error {
	args := []string{"login", "status"}
	codexCommand := wrapBashLoginCommand(formatCommand(cfg.CodexBin, args...))
	sshArgs := buildSSHArgs(cfg, codexCommand)
	logRunf(ctx, "codex command: %s", formatCommand("ssh", sshArgs...))
	cmd := exec.CommandContext(ctx, "ssh", sshArgs...)
	cmd.Env = codexEnv
	out, err := cmd.CombinedOutput()
	logCommandOutput(ctx, "codex login status", out)
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		if isCodexLoginRequiredOutput(msg) {
			return fmt.Errorf(
				"%w; target=%s cmd=%s detail=%s",
				errCodexLoginRequired,
				formatSSHAddress(cfg),
				formatCommand(cfg.CodexBin, args...),
				msg,
			)
		}
		return fmt.Errorf(
			"codex login check failed (target=%s cmd=%s): %s",
			formatSSHAddress(cfg),
			formatCommand(cfg.CodexBin, args...),
			msg,
		)
	}
	return nil
}

func runCodexExec(ctx context.Context, cfg Config, workDir string, codexEnv []string, prompt string) (string, error) {
	args := []string{"exec", "--full-auto", "--skip-git-repo-check", "--cd", workDir, prompt}
	codexCommand := wrapBashLoginCommand(formatCommand(cfg.CodexBin, args...))
	sshArgs := buildSSHArgs(cfg, codexCommand)

	// Avoid logging the full inline prompt while still reflecting argument-mode execution.
	logArgs := []string{"exec", "--full-auto", "--skip-git-repo-check", "--cd", workDir, "<inline-prompt>"}
	logCodexCommand := wrapBashLoginCommand(formatCommand(cfg.CodexBin, logArgs...))
	logSSHArgs := buildSSHArgs(cfg, logCodexCommand)
	logRunf(
		ctx,
		"codex command: %s (prompt_len=%d prompt_preview=%q)",
		formatCommand("ssh", logSSHArgs...),
		len(prompt),
		truncateForLog(prompt, 240),
	)
	cmd := exec.CommandContext(ctx, "ssh", sshArgs...)
	cmd.Env = codexEnv

	out, err := cmd.CombinedOutput()
	logCommandOutput(ctx, "codex exec", out)
	resp := strings.TrimSpace(string(out))
	if err != nil {
		if resp == "" {
			resp = err.Error()
		}
		return resp, fmt.Errorf("%w: %s", err, resp)
	}
	return resp, nil
}

func createRemoteWorkDir(ctx context.Context, cfg Config, codexEnv []string) (string, error) {
	remoteCommand := wrapBashLoginCommand("mktemp -d /tmp/jgo-run-XXXXXX")
	sshArgs := buildSSHArgs(cfg, remoteCommand)
	logRunf(ctx, "codex command: %s", formatCommand("ssh", sshArgs...))

	cmd := exec.CommandContext(ctx, "ssh", sshArgs...)
	cmd.Env = codexEnv
	out, err := cmd.CombinedOutput()
	logCommandOutput(ctx, "remote workdir prepare", out)
	output := strings.TrimSpace(string(out))
	if err != nil {
		return "", fmt.Errorf(
			"prepare remote work dir failed (target=%s, dir=%s): %w: %s",
			formatSSHAddress(cfg),
			"/tmp/jgo-run-XXXXXX",
			err,
			output,
		)
	}
	workDir := parseRemoteWorkDirOutput(output)
	if workDir == "" {
		return "", fmt.Errorf(
			"prepare remote work dir failed (target=%s): empty work dir output=%q",
			formatSSHAddress(cfg),
			output,
		)
	}
	return workDir, nil
}

func cleanupRemoteWorkDir(ctx context.Context, cfg Config, codexEnv []string, workDir string) {
	workDir = strings.TrimSpace(workDir)
	if workDir == "" {
		return
	}

	remoteCommand := wrapBashLoginCommand("rm -rf -- " + shellQuote(workDir))
	sshArgs := buildSSHArgs(cfg, remoteCommand)
	cmd := exec.CommandContext(ctx, "ssh", sshArgs...)
	cmd.Env = codexEnv
	out, err := cmd.CombinedOutput()
	if err != nil {
		logRunf(
			ctx,
			"stage=remote_workdir_cleanup failed: remote_dir=%s err=%v output=%q",
			workDir,
			err,
			truncateForLog(strings.TrimSpace(string(out)), 300),
		)
		return
	}
	logRunf(ctx, "stage=remote_workdir_cleanup done: remote_dir=%s", workDir)
}

func parseRemoteWorkDirOutput(output string) string {
	lines := strings.Split(output, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		if strings.HasPrefix(strings.ToLower(line), "warning:") {
			continue
		}
		return line
	}
	return ""
}

func buildSSHArgs(cfg Config, remoteCommand string) []string {
	args := make([]string, 0, 8)
	if !cfg.SSHStrictHostKeyChecking {
		args = append(args, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null")
	}
	if keyPath := strings.TrimSpace(cfg.SSHKeyPath); keyPath != "" {
		args = append(args, "-i", keyPath, "-o", "IdentitiesOnly=yes")
	}

	target := strings.TrimSpace(cfg.SSHHost)
	if user := strings.TrimSpace(cfg.SSHUser); user != "" {
		target = user + "@" + target
	}

	port := strings.TrimSpace(cfg.SSHPort)
	if port != "" {
		args = append(args, "-p", port)
	}
	args = append(args, target, remoteCommand)
	return args
}

func formatSSHAddress(cfg Config) string {
	target := strings.TrimSpace(cfg.SSHHost)
	if user := strings.TrimSpace(cfg.SSHUser); user != "" {
		target = user + "@" + target
	}
	port := strings.TrimSpace(cfg.SSHPort)
	if port == "" {
		return target
	}
	return target + ":" + port
}

func buildWorkspacePrompt(optimizedPrompt string, availableCLIs []string) string {
	cliList := strings.Join(availableCLIs, ", ")
	if strings.TrimSpace(cliList) == "" {
		cliList = "codex, git"
	}

	return fmt.Sprintf(`You are operating inside a workspace directory.

Available tools/environment:
- codex CLI automation mode
- CLI tools from environment: %s
- KUBECONFIG environment variable may be provided
- OpenAI-compatible endpoints (OpenWebUI/LiteLLM) via environment variables

Execution guidance:
- Use CLI tools listed above when relevant.
- For GitHub-related tasks, use gh when available.
- For Kubernetes-related tasks, use kubectl when available.

Execute this optimized request exactly:
%s

Constraints:
- Use non-interactive commands only.
- Keep changes focused and minimal.
- Do not ask for extra user input.
`, cliList, optimizedPrompt)
}

func buildEditPrompt(repoRef, repoURL, branch, optimizedPrompt string, availableCLIs []string) string {
	cliList := strings.Join(availableCLIs, ", ")
	if strings.TrimSpace(cliList) == "" {
		cliList = "codex, git"
	}

	return fmt.Sprintf(`You are operating inside an empty workspace directory.
Target repository reference from user request: %s
Target repository clone URL: %s
Target branch: %s

Available tools/environment:
- codex CLI automation mode
- CLI tools from environment: %s
- KUBECONFIG environment variable may be provided
- OpenAI-compatible endpoints (OpenWebUI/LiteLLM) via environment variables

Execution guidance:
- Use CLI tools listed above when relevant.
- For GitHub-related tasks, use gh when available.
- For Kubernetes-related tasks, use kubectl when available.

Task:
1. Clone the target repository into ./repo (if already cloned, reuse it).
2. In ./repo, checkout/create branch %s.
3. Execute this optimized request exactly in ./repo:
%s
4. Stop after file changes. Do not commit or push in this step.

Constraints:
- Use non-interactive commands only.
- Keep changes focused and minimal.
- Do not ask for extra user input.
`, repoRef, repoURL, branch, cliList, branch, optimizedPrompt)
}

func buildCommitPushPrompt(repoRef, repoURL, branch string) string {
	return fmt.Sprintf(`You are operating inside a workspace directory.
Target repository reference from user request: %s
Target repository clone URL: %s
Target branch: %s

Task:
1. Ensure target repository exists at ./repo (clone if missing).
2. In ./repo, checkout branch %s (create it if missing).
3. Inspect all staged/unstaged/untracked changes.
4. Split the changes into coherent, minimal commits by topic.
5. Use concise Conventional Commit messages.
6. Commit all current changes.
7. Push to origin %s.

Constraints:
- Use non-interactive commands only. Do not open editors or interactive prompts.
- Do not amend or rewrite existing commits.
- Never force-push.
- Keep each commit focused and internally consistent.
- After each commit, verify that staged content matches the commit message.
- At the end, print the pushed commit list as "<short_sha> <subject>".
`, repoRef, repoURL, branch, branch, branch)
}

func extractRepoRef(instruction string) (string, error) {
	text := strings.TrimSpace(instruction)
	if text == "" {
		return "", fmt.Errorf("instruction is empty")
	}

	urlPattern := regexp.MustCompile(`https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:\.git)?`)
	if m := urlPattern.FindStringSubmatch(text); len(m) > 1 {
		return normalizeRepoRef(m[1]), nil
	}

	plainPattern := regexp.MustCompile(`\b([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\b`)
	matches := plainPattern.FindAllStringSubmatch(text, -1)
	for _, m := range matches {
		if len(m) < 2 {
			continue
		}
		candidate := normalizeRepoRef(m[1])
		parts := strings.Split(candidate, "/")
		if len(parts) != 2 {
			continue
		}
		if parts[0] == "" || parts[1] == "" {
			continue
		}
		return candidate, nil
	}

	return "", fmt.Errorf("instruction must include repository name (owner/repo)")
}

func normalizeRepoRef(s string) string {
	out := strings.TrimSpace(s)
	out = strings.TrimPrefix(out, "/")
	out = strings.TrimSuffix(out, "/")
	out = strings.TrimSuffix(out, ".git")
	out = strings.Trim(out, ".,:;)]}")
	return out
}

func repoURLFromRepoRef(repoRef string) (string, error) {
	ref := strings.TrimSpace(repoRef)
	if ref == "" {
		return "", fmt.Errorf("repository reference is empty")
	}

	if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") {
		if strings.HasSuffix(ref, ".git") {
			return ref, nil
		}
		return ref + ".git", nil
	}

	if strings.Contains(ref, "/") && !strings.Contains(ref, "://") {
		parts := strings.Split(ref, "/")
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			return "https://github.com/" + ref + ".git", nil
		}
	}

	return "", fmt.Errorf("invalid repository reference: %s", repoRef)
}

func applyProviderFallbacks(env map[string]string) {
	if strings.TrimSpace(env["OPENAI_API_KEY"]) == "" {
		if v := strings.TrimSpace(env["OPENWEBUI_API_KEY"]); v != "" {
			env["OPENAI_API_KEY"] = v
		} else if v := strings.TrimSpace(env["LITELLM_API_KEY"]); v != "" {
			env["OPENAI_API_KEY"] = v
		}
	}

	if strings.TrimSpace(env["MODEL"]) == "" {
		if v := strings.TrimSpace(env["OPENWEBUI_MODEL"]); v != "" {
			env["MODEL"] = v
		} else if v := strings.TrimSpace(env["LITELLM_MODEL"]); v != "" {
			env["MODEL"] = v
		}
	}
}

func resolveAvailableCLIs(env map[string]string, codexBin string) []string {
	set := make(map[string]struct{})
	add := func(v string) {
		name := strings.TrimSpace(v)
		if name == "" {
			return
		}
		set[name] = struct{}{}
	}

	add("git")
	if v := strings.TrimSpace(filepath.Base(codexBin)); v != "" {
		add(v)
	} else {
		add("codex")
	}

	if raw := strings.TrimSpace(env["JGO_AVAILABLE_CLIS"]); raw != "" {
		for _, item := range strings.Split(raw, ",") {
			add(item)
		}
	}

	if hasAnyEnv(env, "AWS_ACCESS_KEY_ID", "AWS_PROFILE", "AWS_DEFAULT_REGION", "AWS_REGION") {
		add("aws")
	}
	if hasAnyEnv(env, "GITHUB_TOKEN", "GH_TOKEN") {
		add("gh")
	}
	if hasAnyEnv(env, "KUBECONFIG") {
		add("kubectl")
	}

	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

func hasAnyEnv(env map[string]string, keys ...string) bool {
	for _, key := range keys {
		if strings.TrimSpace(env[key]) != "" {
			return true
		}
	}
	return false
}

func loadEnvFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		raw := scanner.Text()
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		}

		eq := strings.Index(line, "=")
		if eq <= 0 {
			return fmt.Errorf("invalid format at line %d", lineNo)
		}

		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		if strings.HasPrefix(val, "\"") && strings.HasSuffix(val, "\"") && len(val) >= 2 {
			val = strings.Trim(val, "\"")
		} else if strings.HasPrefix(val, "'") && strings.HasSuffix(val, "'") && len(val) >= 2 {
			val = strings.Trim(val, "'")
		}

		if err := os.Setenv(key, val); err != nil {
			return fmt.Errorf("set env (%s) failed at line %d: %w", key, lineNo, err)
		}
	}

	if err := scanner.Err(); err != nil {
		return err
	}
	return nil
}

func environToMap(environ []string) map[string]string {
	result := make(map[string]string, len(environ))
	for _, item := range environ {
		eq := strings.Index(item, "=")
		if eq <= 0 {
			continue
		}
		result[item[:eq]] = item[eq+1:]
	}
	return result
}

func mapToEnviron(env map[string]string) []string {
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, k+"="+env[k])
	}
	return out
}

func formatCommand(bin string, args ...string) string {
	parts := make([]string, 0, len(args)+1)
	parts = append(parts, shellQuote(bin))
	for _, arg := range args {
		parts = append(parts, shellQuote(arg))
	}
	return strings.Join(parts, " ")
}

func wrapBashLoginCommand(command string) string {
	return "bash -lc " + shellQuote(command)
}

func isCodexLoginRequiredOutput(msg string) bool {
	lower := strings.ToLower(strings.TrimSpace(msg))
	if lower == "" {
		return false
	}
	patterns := []string{
		"not logged in",
		"please log in",
		"please login",
		"login required",
		"run codex login",
		"codex login",
	}
	for _, p := range patterns {
		if strings.Contains(lower, p) {
			return true
		}
	}
	return false
}

func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}
