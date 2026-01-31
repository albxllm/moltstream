package gateway

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Client struct {
	url           string
	token         string
	conn          *websocket.Conn
	mu            sync.Mutex
	connected     bool
	connectNonce  string
	onMessage     func(content string, done bool)
	onError       func(err error)
	deviceID      string
	publicKey     string
	privateKey    ed25519.PrivateKey
	reqID         int
	activeRunID   string // Track our active request's runId
	lastContent   string // Track last content to compute deltas
}

type DeviceIdentity struct {
	Version       int    `json:"version"`
	DeviceID      string `json:"deviceId"`
	PublicKeyPem  string `json:"publicKeyPem"`
	PrivateKeyPem string `json:"privateKeyPem"`
}

type GatewayFrame struct {
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Event   string          `json:"event,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *FrameError     `json:"error,omitempty"`
	Ok      bool            `json:"ok,omitempty"`
}

type FrameError struct {
	Code    interface{} `json:"code"` // Can be int or string
	Message string      `json:"message"`
}

type ConnectChallenge struct {
	Nonce string `json:"nonce"`
	Ts    int64  `json:"ts"`
}

type ChatEvent struct {
	RunID   string `json:"runId"`
	Seq     int    `json:"seq"`
	State   string `json:"state"`
	Message struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text,omitempty"`
		} `json:"content,omitempty"`
	} `json:"message,omitempty"`
	ErrorMessage string `json:"errorMessage,omitempty"`
}

func NewClient(url, token string) *Client {
	c := &Client{
		url:   url,
		token: token,
	}
	c.loadDeviceIdentity()
	return c
}

func (c *Client) loadDeviceIdentity() error {
	home, _ := os.UserHomeDir()
	path := filepath.Join(home, ".openclaw", "identity", "device.json")

	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read device identity: %w", err)
	}

	var identity DeviceIdentity
	if err := json.Unmarshal(data, &identity); err != nil {
		return fmt.Errorf("parse device identity: %w", err)
	}

	c.deviceID = identity.DeviceID
	c.publicKey = identity.PublicKeyPem

	block, _ := pem.Decode([]byte(identity.PrivateKeyPem))
	if block == nil {
		return fmt.Errorf("decode private key PEM")
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return fmt.Errorf("parse private key: %w", err)
	}

	edKey, ok := key.(ed25519.PrivateKey)
	if !ok {
		return fmt.Errorf("not ed25519 key")
	}
	c.privateKey = edKey

	return nil
}

func (c *Client) OnMessage(fn func(content string, done bool)) {
	c.onMessage = fn
}

func (c *Client) OnError(fn func(err error)) {
	c.onError = fn
}

func (c *Client) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	conn, _, err := dialer.Dial(c.url, http.Header{})
	if err != nil {
		return fmt.Errorf("websocket dial: %w", err)
	}

	c.conn = conn
	c.connectNonce = ""

	// Don't send connect yet - wait for challenge
	go c.readLoop()

	return nil
}

func (c *Client) readLoop() {
	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if c.onError != nil {
				c.onError(fmt.Errorf("read: %w", err))
			}
			c.mu.Lock()
			c.connected = false
			c.mu.Unlock()
			return
		}

		var frame GatewayFrame
		if err := json.Unmarshal(message, &frame); err != nil {
			log.Printf("parse frame: %v (raw: %s)", err, string(message))
			continue
		}

		c.handleFrame(&frame)
	}
}

func (c *Client) handleFrame(frame *GatewayFrame) {
	switch frame.Type {
	case "event":
		c.handleEvent(frame)
	case "res":
		log.Printf("response: id=%s ok=%v result=%s", frame.ID, frame.Ok, string(frame.Result))
		if frame.Ok {
			// Check if this is a chat.send response with runId
			if frame.ID != "" && len(frame.ID) >= 5 && frame.ID[:5] == "chat-" {
				var result struct {
					RunID string `json:"runId"`
				}
				if err := json.Unmarshal(frame.Result, &result); err == nil && result.RunID != "" {
					c.mu.Lock()
					c.activeRunID = result.RunID
					c.lastContent = ""
					c.mu.Unlock()
					log.Printf("Tracking runId: %s", result.RunID)
				} else {
					log.Printf("failed to extract runId: %v", err)
				}
			}
			// Mark connected on successful connect
			c.mu.Lock()
			c.connected = true
			c.mu.Unlock()
		} else if frame.Error != nil {
			log.Printf("Gateway error: code=%v message=%s", frame.Error.Code, frame.Error.Message)
			if c.onError != nil {
				c.onError(fmt.Errorf("gateway error: %s", frame.Error.Message))
			}
		}
	}
}

func (c *Client) handleEvent(frame *GatewayFrame) {
	log.Printf("Event: %s", frame.Event)
	switch frame.Event {
	case "connect.challenge":
		c.handleChallenge(frame.Payload)
	case "chat":
		c.handleChatEvent(frame.Payload)
	}
}

func (c *Client) handleChallenge(payload json.RawMessage) {
	var challenge ConnectChallenge
	if err := json.Unmarshal(payload, &challenge); err != nil {
		log.Printf("parse challenge: %v", err)
		return
	}

	log.Printf("Received challenge, sending auth connect")
	c.connectNonce = challenge.Nonce
	c.sendConnect()
}

func (c *Client) sendConnect() {
	signedAt := time.Now().UnixMilli()
	// Format: v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
	scopes := "operator.admin"
	token := c.token
	authPayload := fmt.Sprintf("v2|%s|cli|cli|operator|%s|%d|%s|%s",
		c.deviceID, scopes, signedAt, token, c.connectNonce)

	signature := ed25519.Sign(c.privateKey, []byte(authPayload))
	sigB64 := base64.RawURLEncoding.EncodeToString(signature)

	pubKeyRaw := c.privateKey.Public().(ed25519.PublicKey)
	pubKeyB64 := base64.RawURLEncoding.EncodeToString(pubKeyRaw)

	connectFrame := map[string]interface{}{
		"type":   "req",
		"id":     "connect",
		"method": "connect",
		"params": map[string]interface{}{
			"minProtocol": 3,
			"maxProtocol": 3,
			"client": map[string]interface{}{
				"id":       "cli",
				"version":  "0.1.0",
				"platform": "darwin",
				"mode":     "cli",
			},
			"role":   "operator",
			"scopes": []string{"operator.admin"},
			"auth": map[string]interface{}{
				"token": c.token,
			},
			"device": map[string]interface{}{
				"id":        c.deviceID,
				"publicKey": pubKeyB64,
				"signature": sigB64,
				"signedAt":  signedAt,
				"nonce":     c.connectNonce,
			},
		},
	}

	log.Printf("Sending connect with device %s", c.deviceID[:16])
	c.mu.Lock()
	err := c.conn.WriteJSON(connectFrame)
	c.mu.Unlock()

	if err != nil {
		log.Printf("send connect: %v", err)
	}
}

func (c *Client) handleChatEvent(payload json.RawMessage) {
	var event ChatEvent
	if err := json.Unmarshal(payload, &event); err != nil {
		log.Printf("parse chat event: %v", err)
		return
	}

	// Filter: only process events for our active request
	c.mu.Lock()
	activeRunID := c.activeRunID
	lastContent := c.lastContent
	c.mu.Unlock()

	log.Printf("chat event: runId=%s state=%s (tracking=%s)", event.RunID, event.State, activeRunID)

	if activeRunID == "" || event.RunID != activeRunID {
		// Ignore events from other sessions/requests
		log.Printf("ignoring event (runId mismatch or no active request)")
		return
	}

	var fullText string
	if event.Message.Content != nil {
		for _, part := range event.Message.Content {
			if part.Type == "text" {
				fullText += part.Text
			}
		}
	}

	// Compute delta (gateway sends accumulated content, we want incremental)
	delta := ""
	if len(fullText) > len(lastContent) {
		delta = fullText[len(lastContent):]
	}

	// Update last content
	c.mu.Lock()
	c.lastContent = fullText
	c.mu.Unlock()

	done := event.State == "final" || event.State == "error" || event.State == "aborted"

	if done {
		// Clear active run
		c.mu.Lock()
		c.activeRunID = ""
		c.lastContent = ""
		c.mu.Unlock()
	}

	if c.onMessage != nil {
		if event.State == "error" {
			c.onMessage(event.ErrorMessage, true)
		} else if delta != "" || done {
			c.onMessage(delta, done)
		}
	}
}

func (c *Client) Send(content string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.connected || c.conn == nil {
		return fmt.Errorf("not connected")
	}

	c.reqID++
	reqID := fmt.Sprintf("chat-%d", c.reqID)
	frame := map[string]interface{}{
		"type":   "req",
		"id":     reqID,
		"method": "chat.send",
		"params": map[string]interface{}{
			"sessionKey":     "main",
			"message":        content,
			"idempotencyKey": fmt.Sprintf("molt-%d", time.Now().UnixNano()),
		},
	}

	log.Printf("sending chat.send with id=%s", reqID)
	return c.conn.WriteJSON(frame)
}

func (c *Client) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

func (c *Client) Reconnect() error {
	c.Close()
	return c.Connect()
}
