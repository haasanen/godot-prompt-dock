@tool
extends Node
## OpenAI-compatible chat client over raw TCP so replies can STREAM.
## Threading: a worker thread reads the socket; the main thread drains the
## queues via poll() (Godot signals must fire on the main thread).

signal responded(ok: bool, text: String)
signal delta(text: String)          # content fragments as they arrive
signal thinking(text: String)       # reasoning_content fragments (Strata/Qwen)

var base_url: String = "http://localhost:8000/v1"
var model: String = "Qwen3.8-Flash-Next"
var api_key: String = ""
var timeout_ms: int = 300000

var _active := false
var _delta_q := _Queue.new()
var _done_q := _Queue.new()
var _threads: Array = []


class _Queue:
	var _mutex := Mutex.new()
	var _items: Array = []

	func push(item) -> void:
		_mutex.lock()
		_items.append(item)
		_mutex.unlock()

	func try_pop():
		_mutex.lock()
		var v = null
		if not _items.is_empty():
			v = _items.pop_front()
		_mutex.unlock()
		return v


func chat(messages: Array, tools: Array = [], stream: bool = true) -> void:
	if _active:
		responded.emit(false, "a request is already running")
		return
	_active = true
	var body := {
		"model": model,
		"messages": messages,
		"max_tokens": 4096,
		"stream": stream,
	}
	if not tools.is_empty():
		body["tools"] = tools
	var t := Thread.new()
	t.start(_worker.bind(body.duplicate(true), stream))
	_threads.append(t)


## Call every frame (the dock ticks it): forwards deltas, finishes the turn.
func poll() -> void:
	if not _active:
		return
	while true:
		var d = _delta_q.try_pop()
		if d == null:
			break
		if d is Array and d.size() >= 2:
			if d[0] == "think":
				thinking.emit(str(d[1]))
			else:
				delta.emit(str(d[1]))
	var done = _done_q.try_pop()
	if done != null:
		_active = false
		for t in _threads:
			if t.is_started():
				t.wait_to_finish()
		_threads.clear()
		responded.emit(done[0], done[1])


func _last_newline(buf: PackedByteArray) -> int:
	for i in range(buf.size() - 1, -1, -1):
		if buf[i] == 10:  # \n
			return i
	return -1


func _find_bytes(hay: PackedByteArray, needle: PackedByteArray, from: int = 0) -> int:
	if needle.is_empty() or hay.size() < needle.size():
		return -1
	for i in range(from, hay.size() - needle.size() + 1):
		var ok := true
		for j in needle.size():
			if hay[i + j] != needle[j]:
				ok = false
				break
		if ok:
			return i
	return -1


func _worker(body: Dictionary, stream: bool) -> void:
	var parsed = _parse_url(base_url)
	if parsed == null:
		_done_q.push([false, "bad base_url: " + base_url])
		return
	var host: String = parsed["host"]
	var port: int = parsed["port"]
	var path: String = parsed["path"]
	var use_ssl: bool = parsed["ssl"]

	var tcp: StreamPeer = StreamPeerTCP.new()
	if use_ssl:
		tcp = StreamPeerTLS.new()
	if tcp.connect_to_host(host, port) != OK:
		_done_q.push([false, "cannot connect to %s:%d" % [host, port]])
		return
	var deadline := Time.get_ticks_msec() + 15000
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		tcp.poll()
		if Time.get_ticks_msec() > deadline:
			_done_q.push([false, "connect timeout to %s:%d" % [host, port]])
			return
		OS.delay_msec(20)
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_done_q.push([false, "connect failed to %s:%d" % [host, port]])
		return
	if use_ssl:
		if (tcp as StreamPeerTLS).handshake(host) != OK:
			_done_q.push([false, "TLS handshake failed"])
			return

	var auth := ""
	if api_key != "":
		auth = "Authorization: *** %s\r\n" % api_key
	var payload := JSON.stringify(body).to_utf8_buffer()
	var head := ("POST %s/chat/completions HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n" % [path, host, port, auth, payload.size()]).to_utf8_buffer()
	var req := head + payload
	if tcp.put_data(req) != OK:
		_done_q.push([false, "send failed"])
		return

	var deadline2 := Time.get_ticks_msec() + timeout_ms
	var buf := PackedByteArray()
	buf.resize(65536)
	var acc := PackedByteArray()

	# --- headers ---
	var sep := "\r\n\r\n".to_utf8_buffer()
	while _find_bytes(acc, sep) == -1:
		tcp.poll()
		var avail := tcp.get_available_bytes() if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED else 0
		if avail > 0:
			var res := tcp.get_data(mini(avail, 65536))
			if res[0] != OK:
				_done_q.push([false, "read error: " + error_string(res[0])])
				return
			acc.append_array(res[1])
		elif tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_done_q.push([false, "connection closed before headers"])
			return
		else:
			OS.delay_msec(10)
		if Time.get_ticks_msec() > deadline2:
			_done_q.push([false, "header timeout"])
			return
	var split := _find_bytes(acc, sep)
	var headers := acc.slice(0, split).get_string_from_utf8()
	var body_acc := acc.slice(split + 4)
	var code := 0
	var parts := headers.split("\r\n")[0].split(" ")
	if parts.size() >= 2:
		code = parts[1].to_int()
	var chunked := headers.to_lower().contains("transfer-encoding: chunked")
	var content_length := -1
	for line in headers.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			content_length = line.split(":")[1].to_int()

	# --- body ---
	var message_msg := {}
	var saw_data := false
	var finished := false
	var _plain_buf := PackedByteArray()
	while not finished:
		tcp.poll()
		var avail2 := tcp.get_available_bytes() if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED else 0
		if avail2 > 0:
			var res2 := tcp.get_data(mini(avail2, 65536))
			if res2[0] != OK:
				_done_q.push([false, "read error: " + error_string(res2[0])])
				return
			body_acc.append_array(res2[1])
			if chunked:
				var decoded := _decode_chunks(body_acc)
				if decoded[0] != null:
					if stream:
						_process_sse(decoded[0], message_msg)
					else:
						_plain_buf.append_array(decoded[0])
					saw_data = true
				body_acc = decoded[1]
				if decoded[2]:
					finished = true
			elif content_length >= 0 and body_acc.size() >= content_length:
				if stream:
					_process_sse(body_acc, message_msg)
				else:
					_process_plain(body_acc, message_msg)
				saw_data = true
				finished = true
			elif stream and not chunked and content_length == -1:
				# close-delimited SSE: process complete lines as they arrive
				var cut := _last_newline(body_acc)
				if cut != -1:
					_process_sse(body_acc.slice(0, cut + 1), message_msg)
					body_acc = body_acc.slice(cut + 1)
					saw_data = true
		elif tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			if not chunked and body_acc.size() > 0:
				if stream:
					_process_sse(body_acc, message_msg)
				else:
					_process_plain(body_acc, message_msg)
				saw_data = true
			finished = true
		else:
			OS.delay_msec(10)
		if not finished and Time.get_ticks_msec() > deadline2:
			tcp.disconnect_from_host()
			_done_q.push([false, "body timeout"])
			return
	tcp.disconnect_from_host()

	if code != 200:
		_done_q.push([false, "HTTP %d" % code])
		return
	if message_msg.is_empty() and _plain_buf.size() > 0:
		_process_plain(_plain_buf, message_msg)
	if not saw_data and message_msg.is_empty():
		_done_q.push([false, "empty response body"])
		return
	_done_q.push([true, JSON.stringify(message_msg)])


## Returns [flat_sse_bytes_or_null, remaining_acc, terminal_seen].
func _decode_chunks(acc: PackedByteArray) -> Array:
	var out := PackedByteArray()
	var i := 0
	var terminal := false
	var crlf := "\r\n".to_utf8_buffer()
	while true:
		var nl := _find_bytes(acc, crlf, i)
		if nl == -1:
			break
		var size := acc.slice(i, nl).get_string_from_utf8().split(";")[0].strip_edges().hex_to_int()
		if size == 0:
			i = nl + 2
			terminal = true
			break
		if acc.size() < nl + 2 + size + 2:
			break
		out.append_array(acc.slice(nl + 2, nl + 2 + size))
		i = nl + 2 + size + 2
	return [out if out.size() > 0 else null, acc.slice(i), terminal]


func _process_sse(buf: PackedByteArray, message_msg: Dictionary) -> void:
	for line in buf.get_string_from_utf8().split("\n"):
		line = line.strip_edges()
		if not line.begins_with("data:"):
			continue  # SSE comments (": keep-alive") and blanks
		var data := line.substr(5).strip_edges()
		if data == "[DONE]":
			continue
		var j = JSON.parse_string(data)
		if typeof(j) != TYPE_DICTIONARY or not j.has("choices"):
			continue
		var ch = j["choices"]
		if typeof(ch) != TYPE_ARRAY or ch.is_empty():
			continue
		var d: Dictionary = ch[0].get("delta", {})
		var piece := str(d.get("content", ""))
		if piece != "":
			_delta_q.push(["say", piece])
		var think := str(d.get("reasoning_content", ""))
		if think != "":
			_delta_q.push(["think", think])
		_merge_fragment(message_msg, d)


func _process_plain(body_bytes: PackedByteArray, message_msg: Dictionary) -> void:
	var j = JSON.parse_string(body_bytes.get_string_from_utf8())
	if typeof(j) == TYPE_DICTIONARY and j.has("choices"):
		var ch = j["choices"]
		if typeof(ch) == TYPE_ARRAY and not ch.is_empty():
			var m = ch[0].get("message", {})
			if typeof(m) == TYPE_DICTIONARY:
				message_msg.merge(m, true)


## Merge streaming delta fragments (content, tool_calls) into one message dict.
func _merge_fragment(msg: Dictionary, d: Dictionary) -> void:
	if d.has("content") and str(d["content"]) != "":
		msg["content"] = str(msg.get("content", "")) + str(d["content"])
	var tcs = d.get("tool_calls", [])
	if typeof(tcs) == TYPE_ARRAY and not (tcs as Array).is_empty():
		var acc_tcs: Array = msg.get("tool_calls", [])
		for tc in tcs:
			var id := str(tc.get("id", ""))
			var f_in: Dictionary = tc.get("function", {})
			if id != "" or acc_tcs.is_empty():
				acc_tcs.append({
					"id": id,
					"type": "function",
					"function": {
						"name": str(f_in.get("name", "")),
						"arguments": str(f_in.get("arguments", "")),
					},
				})
			else:
				var f: Dictionary = acc_tcs[acc_tcs.size() - 1]["function"]
				f["name"] = str(f["name"]) + str(f_in.get("name", ""))
				f["arguments"] = str(f["arguments"]) + str(f_in.get("arguments", ""))
		msg["tool_calls"] = acc_tcs


func _parse_url(u: String):
	var lower := u.to_lower().trim_suffix("/")
	var ssl := false
	if lower.begins_with("https://"):
		ssl = true
		lower = lower.substr(8)
	elif lower.begins_with("http://"):
		lower = lower.substr(7)
	else:
		return null
	var slash := lower.find("/")
	var hostport := lower if slash == -1 else lower.substr(0, slash)
	var path := "" if slash == -1 else lower.substr(slash)
	var port := 443 if ssl else 80
	var colon := hostport.rfind(":")
	var host := hostport
	if colon != -1:
		host = hostport.substr(0, colon)
		port = hostport.substr(colon + 1).to_int()
	return {"host": host, "port": port, "path": path, "ssl": ssl}
