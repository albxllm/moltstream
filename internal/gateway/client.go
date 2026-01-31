package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Client struct {
	url       string
	token     string
	conn      *websocket.Conn
	mu        sync.Mutex
	connected bool
	onMessage func(content string, done bool)
	onError   func(err error)
	ctx       context.Context
	cancel    context.CancelFunc
}

type GatewayMessage struct {
	Type    string `json:"type"`
	Content string `json:"content,omitempty"`
	Delta   string `json:"delta,omitempty"`
	Done    bool   `json:"done,omitempty"`
	Error   string `json:"error,omitempty"`
}

func NewClient(url, token string) *Client {
	ctx, cancel := context.WithCancel(context.Background())
	return &Client{
		url:    url,
		token:  token,
		ctx:    ctx,
		cancel: cancel,
	}
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

	header := http.Header{}
	header.Set("Authorization", "Bearer "+c.token)

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
	}

	conn, _, err := dialer.Dial(c.url, header)
	if err != nil {
		return fmt.Errorf("websocket dial: %w", err)
	}

	c.conn = conn
	c.connected = true

	go c.readLoop()

	return nil
}

func (c *Client) readLoop() {
	defer func() {
		c.mu.Lock()
		c.connected = false
		c.mu.Unlock()
	}()

	for {
		select {
		case <-c.ctx.Done():
			return
		default:
		}

		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				if c.onError != nil {
					c.onError(fmt.Errorf("websocket read: %w", err))
				}
			}
			return
		}

		var msg GatewayMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			log.Printf("parse gateway message: %v", err)
			continue
		}

		switch msg.Type {
		case "stream", "delta":
			if c.onMessage != nil {
				c.onMessage(msg.Delta, msg.Done)
			}
		case "response", "message":
			if c.onMessage != nil {
				c.onMessage(msg.Content, true)
			}
		case "error":
			if c.onError != nil {
				c.onError(fmt.Errorf("gateway error: %s", msg.Error))
			}
		}
	}
}

func (c *Client) Send(content string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.connected || c.conn == nil {
		return fmt.Errorf("not connected")
	}

	msg := map[string]interface{}{
		"type":    "message",
		"content": content,
	}

	return c.conn.WriteJSON(msg)
}

func (c *Client) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

func (c *Client) Close() error {
	c.cancel()
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

func (c *Client) Reconnect() error {
	c.Close()
	c.ctx, c.cancel = context.WithCancel(context.Background())
	return c.Connect()
}
