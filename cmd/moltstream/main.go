package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/albxllm/moltstream/internal/gateway"
	"github.com/albxllm/moltstream/internal/protocol"
	"github.com/albxllm/moltstream/internal/session"
	"gopkg.in/yaml.v3"
)

type Config struct {
	Gateway struct {
		URL   string `yaml:"url"`
		Token string `yaml:"token"`
	} `yaml:"gateway"`
	Session struct {
		Directory    string `yaml:"directory"`
		MaxSizeBytes int64  `yaml:"max_size_bytes"`
		AutoArchive  bool   `yaml:"auto_archive"`
	} `yaml:"session"`
}

type Bridge struct {
	config  *Config
	client  *gateway.Client
	session *session.Manager
	encoder *json.Encoder
	decoder *json.Decoder
	reqID   int
}

func main() {
	log.SetFlags(0)
	log.SetPrefix("[moltstream] ")

	config, err := loadConfig()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	// Expand env vars in token
	if config.Gateway.Token == "${OPENCLAW_TOKEN}" {
		config.Gateway.Token = os.Getenv("OPENCLAW_TOKEN")
	}

	if config.Gateway.Token == "" {
		log.Fatal("OPENCLAW_TOKEN not set")
	}

	bridge, err := NewBridge(config)
	if err != nil {
		log.Fatalf("create bridge: %v", err)
	}

	// Handle signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		bridge.Close()
		os.Exit(0)
	}()

	// Connect to gateway
	if err := bridge.Connect(); err != nil {
		log.Fatalf("connect: %v", err)
	}

	// Process stdin
	bridge.Run()
}

func loadConfig() (*Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}

	configPath := filepath.Join(home, ".config", "moltstream", "config.yaml")

	data, err := os.ReadFile(configPath)
	if err != nil {
		// Return defaults if no config
		return &Config{
			Gateway: struct {
				URL   string `yaml:"url"`
				Token string `yaml:"token"`
			}{
				URL:   "ws://100.104.217.17:3000/api/sessions/main/ws",
				Token: "${OPENCLAW_TOKEN}",
			},
			Session: struct {
				Directory    string `yaml:"directory"`
				MaxSizeBytes int64  `yaml:"max_size_bytes"`
				AutoArchive  bool   `yaml:"auto_archive"`
			}{
				Directory:    "~/.local/share/moltstream",
				MaxSizeBytes: 1073741824, // 1GB
				AutoArchive:  true,
			},
		}, nil
	}

	var config Config
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	return &config, nil
}

func NewBridge(config *Config) (*Bridge, error) {
	sess, err := session.NewManager(
		config.Session.Directory,
		config.Session.MaxSizeBytes,
		config.Session.AutoArchive,
	)
	if err != nil {
		return nil, fmt.Errorf("session manager: %w", err)
	}

	client := gateway.NewClient(config.Gateway.URL, config.Gateway.Token)

	return &Bridge{
		config:  config,
		client:  client,
		session: sess,
		encoder: json.NewEncoder(os.Stdout),
		decoder: json.NewDecoder(os.Stdin),
	}, nil
}

func (b *Bridge) Connect() error {
	b.client.OnMessage(b.handleGatewayMessage)
	b.client.OnError(b.handleGatewayError)

	if err := b.client.Connect(); err != nil {
		return err
	}

	// Notify nvim of connection
	b.sendNotification("connected", map[string]interface{}{
		"gateway": b.config.Gateway.URL,
	})

	return nil
}

func (b *Bridge) Run() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024) // 1MB buffer

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req protocol.Request
		if err := json.Unmarshal(line, &req); err != nil {
			b.sendError(0, protocol.ErrParse, "parse error")
			continue
		}

		b.handleRequest(&req)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("stdin error: %v", err)
	}
}

func (b *Bridge) handleRequest(req *protocol.Request) {
	id := 0
	if req.ID != nil {
		id = *req.ID
	}

	switch req.Method {
	case "send":
		var params protocol.SendParams
		if err := json.Unmarshal(req.Params, &params); err != nil {
			b.sendError(id, protocol.ErrInvalidParams, "invalid params")
			return
		}
		b.handleSend(id, params.Content)

	case "status":
		b.handleStatus(id)

	case "reconnect":
		b.handleReconnect(id)

	case "archive":
		b.handleArchive(id)

	case "session_path":
		b.handleSessionPath(id)

	default:
		b.sendError(id, protocol.ErrMethodNotFound, "method not found")
	}
}

func (b *Bridge) handleSend(id int, content string) {
	if !b.client.IsConnected() {
		b.sendError(id, protocol.ErrNotConnected, "not connected to gateway")
		return
	}

	if err := b.client.Send(content); err != nil {
		b.sendError(id, protocol.ErrGatewayError, err.Error())
		return
	}

	// Response will come async via handleGatewayMessage
	b.reqID = id
}

func (b *Bridge) handleStatus(id int) {
	result := protocol.StatusResult{
		Connected: b.client.IsConnected(),
		SessionID: "", // TODO: track session ID
		Gateway:   b.config.Gateway.URL,
	}
	b.sendResult(id, result)
}

func (b *Bridge) handleReconnect(id int) {
	if err := b.client.Reconnect(); err != nil {
		b.sendError(id, protocol.ErrGatewayError, err.Error())
		return
	}
	b.sendResult(id, map[string]string{"status": "reconnected"})
}

func (b *Bridge) handleArchive(id int) {
	if err := b.session.Archive(); err != nil {
		b.sendError(id, protocol.ErrInternal, err.Error())
		return
	}
	path, _ := b.session.EnsureSession()
	b.sendResult(id, map[string]string{"status": "archived", "path": path})
}

func (b *Bridge) handleSessionPath(id int) {
	path, err := b.session.EnsureSession()
	if err != nil {
		b.sendError(id, protocol.ErrInternal, err.Error())
		return
	}
	b.sendResult(id, map[string]string{"path": path})
}

func (b *Bridge) handleGatewayMessage(content string, done bool) {
	b.sendNotification("stream", protocol.StreamParams{
		Delta: content,
		Done:  done,
	})

	if done && b.reqID != 0 {
		b.sendResult(b.reqID, map[string]string{"status": "ok"})
		b.reqID = 0
	}
}

func (b *Bridge) handleGatewayError(err error) {
	b.sendNotification("error", protocol.ErrorResult{
		Message: err.Error(),
	})
}

func (b *Bridge) sendResult(id int, result interface{}) {
	resp, _ := protocol.NewResponse(id, result)
	b.encoder.Encode(resp)
}

func (b *Bridge) sendError(id int, code int, message string) {
	resp := protocol.NewErrorResponse(id, code, message)
	b.encoder.Encode(resp)
}

func (b *Bridge) sendNotification(method string, params interface{}) {
	notif, _ := protocol.NewNotification(method, params)
	b.encoder.Encode(notif)
}

func (b *Bridge) Close() {
	b.client.Close()
}
