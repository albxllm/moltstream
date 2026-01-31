package gateway

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
)

// Client wraps openclaw CLI for gateway communication
type Client struct {
	sessionID string
	mu        sync.Mutex
	onMessage func(content string, done bool)
	onError   func(err error)
}

func NewClient(url, token string) *Client {
	// URL and token not used - we use CLI instead
	return &Client{
		sessionID: "moltstream",
	}
}

func (c *Client) OnMessage(fn func(content string, done bool)) {
	c.onMessage = fn
}

func (c *Client) OnError(fn func(err error)) {
	c.onError = fn
}

func (c *Client) Connect() error {
	// No persistent connection needed with CLI approach
	return nil
}

func (c *Client) IsConnected() bool {
	return true // Always "connected" since we use CLI
}

func (c *Client) Send(content string) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 600*1000*1000*1000) // 600s
	defer cancel()

	// Use openclaw agent command
	cmd := exec.CommandContext(ctx, "openclaw", "agent",
		"--session-id", c.sessionID,
		"--message", content,
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start command: %w", err)
	}

	// Read stdout line by line and stream to callback
	go func() {
		scanner := bufio.NewScanner(stdout)
		var fullResponse strings.Builder
		
		for scanner.Scan() {
			line := scanner.Text()
			fullResponse.WriteString(line)
			fullResponse.WriteString("\n")
			
			if c.onMessage != nil {
				c.onMessage(line+"\n", false)
			}
		}
		
		// Signal completion
		if c.onMessage != nil {
			c.onMessage("", true)
		}
	}()

	// Read stderr for errors
	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			line := scanner.Text()
			if c.onError != nil && line != "" {
				c.onError(fmt.Errorf("%s", line))
			}
		}
	}()

	// Wait for completion in background
	go func() {
		if err := cmd.Wait(); err != nil {
			if c.onError != nil {
				c.onError(fmt.Errorf("command failed: %w", err))
			}
		}
	}()

	return nil
}

func (c *Client) Close() error {
	return nil
}

func (c *Client) Reconnect() error {
	return nil
}
