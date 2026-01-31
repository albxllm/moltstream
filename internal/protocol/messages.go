package protocol

import "encoding/json"

// JSON-RPC 2.0 types

type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
	ID      *int            `json:"id,omitempty"`
}

type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
	ID      *int            `json:"id,omitempty"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type Notification struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Application-specific params

type SendParams struct {
	Content string `json:"content"`
}

type StreamParams struct {
	Delta string `json:"delta"`
	Done  bool   `json:"done"`
}

type StatusResult struct {
	Connected bool   `json:"connected"`
	SessionID string `json:"session_id"`
	Gateway   string `json:"gateway"`
}

type ErrorResult struct {
	Message string `json:"message"`
}

// Helper constructors

func NewRequest(method string, params interface{}, id int) (*Request, error) {
	p, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	return &Request{
		JSONRPC: "2.0",
		Method:  method,
		Params:  p,
		ID:      &id,
	}, nil
}

func NewNotification(method string, params interface{}) (*Notification, error) {
	p, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	return &Notification{
		JSONRPC: "2.0",
		Method:  method,
		Params:  p,
	}, nil
}

func NewResponse(id int, result interface{}) (*Response, error) {
	r, err := json.Marshal(result)
	if err != nil {
		return nil, err
	}
	return &Response{
		JSONRPC: "2.0",
		Result:  r,
		ID:      &id,
	}, nil
}

func NewErrorResponse(id int, code int, message string) *Response {
	return &Response{
		JSONRPC: "2.0",
		Error: &RPCError{
			Code:    code,
			Message: message,
		},
		ID: &id,
	}
}

// Error codes
const (
	ErrParse       = -32700
	ErrInvalidReq  = -32600
	ErrMethodNotFound = -32601
	ErrInvalidParams  = -32602
	ErrInternal    = -32603
	ErrNotConnected = -32000
	ErrGatewayError = -32001
)
