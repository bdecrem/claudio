package ws

import "encoding/json"

// RPCMessage is the type-peek for incoming messages
type RPCMessage struct {
	Type   string          `json:"type"`
	ID     string          `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Event  string          `json:"event,omitempty"`
}

// RPCRequest is a parsed incoming request
type RPCRequest struct {
	ID     string
	Method string
	Params map[string]json.RawMessage
}

// RPCResponse is an outgoing response
type RPCResponse struct {
	Type    string      `json:"type"`
	ID      string      `json:"id"`
	OK      bool        `json:"ok"`
	Payload interface{} `json:"payload,omitempty"`
	Error   *RPCError   `json:"error,omitempty"`
}

type RPCError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// RPCEvent is an outgoing event
type RPCEvent struct {
	Type    string      `json:"type"`
	Event   string      `json:"event"`
	Payload interface{} `json:"payload,omitempty"`
}

func NewResponse(id string, payload interface{}) RPCResponse {
	return RPCResponse{Type: "res", ID: id, OK: true, Payload: payload}
}

func NewErrorResponse(id, code, message string) RPCResponse {
	return RPCResponse{
		Type:  "res",
		ID:    id,
		OK:    false,
		Error: &RPCError{Code: code, Message: message},
	}
}

func NewEvent(event string, payload interface{}) RPCEvent {
	return RPCEvent{Type: "event", Event: event, Payload: payload}
}
