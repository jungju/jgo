package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const defaultCacheDir = "/jgo-cache"

type Config struct {
	CodexBin string
	CacheDir string
}

type OpenAIConfig struct {
	BaseURL string
	APIKey  string
	Model   string
}

type CacheLayout struct {
	RootDir  string
	ReposDir string
	WorkDir  string
}

type RequestPlan struct {
	Executable      bool   `json:"executable"`
	Reason          string `json:"reason"`
	RepoRef         string `json:"repo_ref"`
	OptimizedPrompt string `json:"optimized_prompt"`
}

type chatRequest struct {
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

type chatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "run":
		if err := runCommand(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
	default:
		printUsage()
		os.Exit(1)
	}
}

func runCommand(args []string) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() == 0 {
		return fmt.Errorf("missing instruction")
	}

	instruction := strings.TrimSpace(strings.Join(fs.Args(), " "))
	if instruction == "" {
		return fmt.Errorf("instruction cannot be empty")
	}

	cfg, err := loadConfigFromEnv()
	if err != nil {
		return err
	}

	return runAutomation(context.Background(), cfg, instruction)
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "usage: jgo run \"<instruction>\"")
}

func loadConfigFromEnv() (Config, error) {
	cfg := Config{
		CodexBin: strings.TrimSpace(os.Getenv("CODEX_BIN")),
		CacheDir: strings.TrimSpace(os.Getenv("JGO_CACHE_DIR")),
	}

	if cfg.CodexBin == "" {
		cfg.CodexBin = "codex"
	}

	return cfg, nil
}

func runAutomation(ctx context.Context, cfg Config, instruction string) error {
	envMap := environToMap(os.Environ())
	applyProviderFallbacks(envMap)
	cacheDir := resolveCacheDir(cfg.CacheDir, envMap)
	envMap["JGO_CACHE_DIR"] = cacheDir

	openaiCfg, err := loadOpenAIConfig(envMap)
	if err != nil {
		return err
	}

	plan, err := analyzeRequest(ctx, openaiCfg, instruction)
	if err != nil {
		return fmt.Errorf("analyze request: %w", err)
	}
	if !plan.Executable {
		reason := strings.TrimSpace(plan.Reason)
		if reason == "" {
			reason = "request is not executable"
		}
		return fmt.Errorf("request is not executable: %s", reason)
	}

	repoRef := normalizeRepoRef(plan.RepoRef)
	if repoRef == "" {
		repoRef, err = extractRepoRef(instruction)
		if err != nil {
			return fmt.Errorf("missing repository reference in optimized plan: %w", err)
		}
	}
	repoURL, err := repoURLFromRepoRef(repoRef)
	if err != nil {
		return err
	}

	optimizedPrompt := strings.TrimSpace(plan.OptimizedPrompt)
	if optimizedPrompt == "" {
		optimizedPrompt = instruction
	}

	if _, err := exec.LookPath(cfg.CodexBin); err != nil {
		return fmt.Errorf("%s CLI is required in PATH", cfg.CodexBin)
	}

	codexEnv := mapToEnviron(envMap)
	if err := ensureCodexLogin(ctx, cfg.CodexBin, codexEnv); err != nil {
		return err
	}

	cacheLayout, err := ensureCacheLayout(cacheDir)
	if err != nil {
		return err
	}

	workDir, err := os.MkdirTemp(cacheLayout.WorkDir, "run-*")
	if err != nil {
		return fmt.Errorf("create work dir: %w", err)
	}
	defer os.RemoveAll(workDir)

	mirrorDir := repoMirrorPath(cacheLayout.ReposDir, repoURL)
	if err := syncRepoMirror(ctx, repoURL, mirrorDir); err != nil {
		return fmt.Errorf("sync repo cache: %w", err)
	}

	repoDir := filepath.Join(workDir, "repo")
	if err := gitCloneFromMirror(ctx, mirrorDir, repoURL, repoDir); err != nil {
		return fmt.Errorf("clone from cache: %w", err)
	}
	if err := ensureOriginRemote(ctx, repoDir); err != nil {
		return err
	}

	branch := fmt.Sprintf("jgo/%s", time.Now().UTC().Format("20060102-150405"))
	if err := gitCheckoutNewBranch(ctx, repoDir, branch); err != nil {
		return fmt.Errorf("create branch: %w", err)
	}

	if err := runCodexExec(ctx, cfg.CodexBin, repoDir, codexEnv, buildEditPrompt(repoRef, branch, optimizedPrompt)); err != nil {
		return fmt.Errorf("codex edit failed: %w", err)
	}

	hasChanges, err := gitHasChanges(ctx, repoDir)
	if err != nil {
		return err
	}
	if !hasChanges {
		return fmt.Errorf("codex produced no changes")
	}

	if err := runCodexExec(ctx, cfg.CodexBin, repoDir, codexEnv, buildCommitPushPrompt(repoRef, branch)); err != nil {
		return fmt.Errorf("codex commit/push failed: %w", err)
	}

	fmt.Println(branch)
	return nil
}

func resolveCacheDir(configCacheDir string, env map[string]string) string {
	if v := strings.TrimSpace(configCacheDir); v != "" {
		return v
	}
	if v := strings.TrimSpace(env["JGO_CACHE_DIR"]); v != "" {
		return v
	}
	return defaultCacheDir
}

func loadOpenAIConfig(env map[string]string) (OpenAIConfig, error) {
	cfg := OpenAIConfig{
		BaseURL: strings.TrimSpace(env["OPENAI_BASE_URL"]),
		APIKey:  strings.TrimSpace(env["OPENAI_API_KEY"]),
		Model:   strings.TrimSpace(env["MODEL"]),
	}

	var missing []string
	if cfg.BaseURL == "" {
		missing = append(missing, "OPENAI_BASE_URL")
	}
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

func analyzeRequest(ctx context.Context, cfg OpenAIConfig, instruction string) (RequestPlan, error) {
	reqBody := chatRequest{
		Model:          cfg.Model,
		Temperature:    0.2,
		ResponseFormat: responseFormat{Type: "json_object"},
		Messages: []chatMessage{
			{
				Role:    "system",
				Content: "Return strict JSON only with keys: executable(boolean), reason(string), repo_ref(string), optimized_prompt(string). Mark executable=true only when the request can be executed non-interactively in a git repository and includes a repository reference (owner/repo or GitHub URL). If executable=false, explain what is missing in reason. If executable=true, generate a clear Codex-optimized prompt in optimized_prompt.",
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
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return RequestPlan{}, fmt.Errorf("request failed: %s: %s", resp.Status, strings.TrimSpace(string(respBody)))
	}

	var chatResp chatResponse
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

	plan.Reason = strings.TrimSpace(plan.Reason)
	plan.RepoRef = normalizeRepoRef(plan.RepoRef)
	plan.OptimizedPrompt = strings.TrimSpace(plan.OptimizedPrompt)

	if plan.Executable {
		if plan.OptimizedPrompt == "" {
			return RequestPlan{}, fmt.Errorf("parse plan json: optimized_prompt is required when executable is true")
		}
	} else {
		if plan.Reason == "" {
			plan.Reason = "request cannot be executed"
		}
	}

	return plan, nil
}

func ensureCodexLogin(ctx context.Context, codexBin string, codexEnv []string) error {
	cmd := exec.CommandContext(ctx, codexBin, "login", "status")
	cmd.Env = codexEnv
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = "login status command failed"
		}
		return fmt.Errorf("codex login is required; start your OpenAI-compatible API server and run `%s login` first: %s", codexBin, msg)
	}
	return nil
}

func runCodexExec(ctx context.Context, codexBin, repoDir string, codexEnv []string, prompt string) error {
	cmd := exec.CommandContext(ctx, codexBin, "exec", "--full-auto", "--cd", repoDir, "-")
	cmd.Env = codexEnv
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return err
	}
	return nil
}

func buildEditPrompt(repoRef, branch, optimizedPrompt string) string {
	return fmt.Sprintf(`You are in a local git repository on branch %s.
Target repository reference from user request: %s

Available tools/environment:
- codex CLI automation mode
- git, aws CLI, gh CLI, kubectl CLI
- KUBECONFIG environment variable may be provided
- OpenAI-compatible endpoints (OpenWebUI/LiteLLM) via environment variables

Execute this optimized request exactly:
%s

Constraints:
- Use non-interactive commands only.
- Keep changes focused and minimal.
- Do not commit or push in this step.
`, branch, repoRef, optimizedPrompt)
}

func buildCommitPushPrompt(repoRef, branch string) string {
	return fmt.Sprintf(`You are in a local git repository. Commit and push the current working tree.
Target repository reference from user request: %s

Task:
1. Inspect all staged/unstaged/untracked changes.
2. Split the changes into coherent, minimal commits by topic.
3. Use concise Conventional Commit messages.
4. Commit all current changes.
5. Push to origin %s.

Constraints:
- Use non-interactive commands only. Do not open editors or interactive prompts.
- Do not amend or rewrite existing commits.
- Never force-push.
- Keep each commit focused and internally consistent.
- After each commit, verify that staged content matches the commit message.
- At the end, print the pushed commit list as "<short_sha> <subject>".
`, repoRef, branch)
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
	if strings.TrimSpace(env["OPENAI_BASE_URL"]) == "" {
		if v := strings.TrimSpace(env["OPENWEBUI_BASE_URL"]); v != "" {
			env["OPENAI_BASE_URL"] = v
		} else if v := strings.TrimSpace(env["LITELLM_BASE_URL"]); v != "" {
			env["OPENAI_BASE_URL"] = v
		}
	}

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

func ensureCacheLayout(root string) (CacheLayout, error) {
	cacheRoot := filepath.Clean(strings.TrimSpace(root))
	if cacheRoot == "" || cacheRoot == "." {
		return CacheLayout{}, fmt.Errorf("invalid cache dir: %q", root)
	}

	layout := CacheLayout{
		RootDir:  cacheRoot,
		ReposDir: filepath.Join(cacheRoot, "repos"),
		WorkDir:  filepath.Join(cacheRoot, "work"),
	}

	for _, dir := range []string{layout.RootDir, layout.ReposDir, layout.WorkDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return CacheLayout{}, fmt.Errorf("create cache dir (%s): %w", dir, err)
		}
	}

	return layout, nil
}

func repoMirrorPath(reposDir, repoURL string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(repoURL)))
	hash := hex.EncodeToString(sum[:12])
	slug := repoCacheSlug(repoURL)
	return filepath.Join(reposDir, slug+"-"+hash+".git")
}

func repoCacheSlug(repoURL string) string {
	candidate := normalizeRepoRef(repoURL)
	if m := regexp.MustCompile(`([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$`).FindStringSubmatch(candidate); len(m) > 1 {
		candidate = m[1]
	}
	candidate = strings.ToLower(candidate)
	var b strings.Builder
	prevDash := false
	for _, r := range candidate {
		isAlpha := r >= 'a' && r <= 'z'
		isNum := r >= '0' && r <= '9'
		if isAlpha || isNum {
			b.WriteRune(r)
			prevDash = false
			continue
		}
		if !prevDash {
			b.WriteByte('-')
			prevDash = true
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "repo"
	}
	return out
}

func syncRepoMirror(ctx context.Context, repoURL, mirrorDir string) error {
	if st, err := os.Stat(mirrorDir); err == nil {
		if !st.IsDir() {
			return fmt.Errorf("repo cache path is not a directory: %s", mirrorDir)
		}
		if err := runGit(ctx, mirrorDir, "remote", "set-url", "origin", repoURL); err != nil {
			return err
		}
		if err := runGit(ctx, mirrorDir, "remote", "update", "--prune"); err != nil {
			return err
		}
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}

	return runGit(ctx, "", "clone", "--mirror", repoURL, mirrorDir)
}

func gitCloneFromMirror(ctx context.Context, mirrorDir, repoURL, repoDir string) error {
	if err := runGit(ctx, "", "clone", mirrorDir, repoDir); err != nil {
		return err
	}
	return runGit(ctx, repoDir, "remote", "set-url", "origin", repoURL)
}

func gitCheckoutNewBranch(ctx context.Context, repoDir, branch string) error {
	return runGit(ctx, repoDir, "checkout", "-b", branch)
}

func ensureOriginRemote(ctx context.Context, repoDir string) error {
	if _, err := runGitOutput(ctx, repoDir, "remote", "get-url", "origin"); err != nil {
		return fmt.Errorf("git remote 'origin' does not exist: %w", err)
	}
	return nil
}

func gitHasChanges(ctx context.Context, repoDir string) (bool, error) {
	out, err := runGitOutput(ctx, repoDir, "status", "--porcelain")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(out) != "", nil
}

func runGit(ctx context.Context, dir string, args ...string) error {
	_, err := runGitOutput(ctx, dir, args...)
	return err
}

func runGitOutput(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	if dir != "" {
		cmd.Dir = dir
	}

	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s failed: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}
