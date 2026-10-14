// A stand-in for the Anthropic Messages API on 127.0.0.1, so a real Claude
// Code runs a real session on a test PC with no account. It answers from a
// script keyed on markers in the person's last message:
//
//   PROOF-WRITE <absolute path>   a Write tool call for that file (asks permission)
//   PROOF-BASH <command>          a Bash tool call (PowerShell where Bash is absent)
//   PROOF-HELPER                  a plain answer held back HELPER_MS, so the
//                                 helper Claude Code stays alive to be seen
//
// After a tool result it says "PROOF-DONE"; anything else gets "ok". Every
// request is logged, one JSON line each, to the file named by argv[3].
//
//   node stub.js <port> <log file>
"use strict";
const http = require("http");
const fs = require("fs");

const port = Number(process.argv[2] || 4545);
const logFile = process.argv[3] || "stub.log";
const HELPER_MS = Number(process.env.PROOF_HELPER_MS || 60000);
let n = 0;

function log(o) {
  try { fs.appendFileSync(logFile, JSON.stringify({ t: new Date().toISOString(), ...o }) + "\n"); } catch (_) {}
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((b) => (b && b.type === "text" ? b.text : "")).join("\n");
}

// The conversation's last turn: Claude Code 2.1 puts its environment after
// the person's message as a message of role "system", which is not a turn.
function lastTurn(body) {
  const msgs = Array.isArray(body.messages) ? body.messages : [];
  const turns = msgs.filter((m) => m && (m.role === "user" || m.role === "assistant"));
  return turns[turns.length - 1] || {};
}

function decide(body) {
  const last = lastTurn(body);
  const tools = Array.isArray(body.tools) ? body.tools.map((t) => t && t.name).filter(Boolean) : [];
  const blocks = Array.isArray(last.content) ? last.content : [];
  if (last.role === "user" && blocks.some((b) => b && b.type === "tool_result")) {
    return { kind: "text", text: "PROOF-DONE" };
  }
  const text = last.role === "user" ? textOf(last.content) : "";
  let m;
  if ((m = /PROOF-WRITE\s+(\S+)/.exec(text)) && tools.includes("Write")) {
    return { kind: "tool", name: "Write", input: { file_path: m[1], content: "written by the proof harness\n" } };
  }
  if ((m = /PROOF-BASH\s+([^\r\n]+)/.exec(text))) {
    const command = m[1].trim();
    if (tools.includes("Bash")) return { kind: "tool", name: "Bash", input: { command, description: "Proof step" } };
    if (tools.includes("PowerShell")) return { kind: "tool", name: "PowerShell", input: { command, description: "Proof step" } };
  }
  if (/PROOF-HELPER/.test(text) && tools.length > 0) {
    return { kind: "text", text: "PROOF-HELPER-DONE", delay: HELPER_MS };
  }
  return { kind: "text", text: "ok" };
}

function usage() {
  return { input_tokens: 12, output_tokens: 3, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
}

function message(model, d, id) {
  const content = d.kind === "tool"
    ? [{ type: "tool_use", id: "toolu_proof_" + id, name: d.name, input: d.input }]
    : [{ type: "text", text: d.text }];
  return {
    id: "msg_proof_" + id, type: "message", role: "assistant", model,
    content, stop_reason: d.kind === "tool" ? "tool_use" : "end_turn", stop_sequence: null, usage: usage(),
  };
}

function sse(res, model, d, id) {
  const send = (event, data) => res.write("event: " + event + "\ndata: " + JSON.stringify(data) + "\n\n");
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive", "request-id": "req_proof_" + id });
  const start = message(model, d, id);
  send("message_start", { type: "message_start", message: { ...start, content: [], stop_reason: null, usage: usage() } });
  if (d.kind === "tool") {
    send("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_proof_" + id, name: d.name, input: {} } });
    send("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(d.input) } });
  } else {
    send("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    send("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: d.text } });
  }
  send("content_block_stop", { type: "content_block_stop", index: 0 });
  send("message_delta", { type: "message_delta", delta: { stop_reason: start.stop_reason, stop_sequence: null }, usage: { output_tokens: 3 } });
  send("message_stop", { type: "message_stop" });
  res.end();
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const id = ++n;
    const raw = Buffer.concat(chunks).toString("utf8");
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch (_) {}
    const path = (req.url || "").split("?")[0];
    if (process.env.PROOF_DUMP) {
      try { fs.writeFileSync(require("path").join(process.env.PROOF_DUMP, String(id).padStart(3, "0") + ".json"), raw); } catch (_) {}
    }
    if (req.method === "POST" && path === "/v1/messages/count_tokens") {
      log({ id, method: req.method, url: req.url, answer: "count_tokens" });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ input_tokens: 100 }));
    }
    if (req.method === "POST" && path === "/v1/messages") {
      const d = decide(body);
      const model = body.model || "claude-proof";
      const last = lastTurn(body);
      log({
        id, method: req.method, url: req.url, model, stream: !!body.stream,
        tools: Array.isArray(body.tools) ? body.tools.length : 0,
        last: textOf(last.content).slice(-160), answer: d.kind === "tool" ? d.name + " " + JSON.stringify(d.input) : d.text,
        delay: d.delay || 0,
      });
      const answer = () => {
        if (body.stream) return sse(res, model, d, id);
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(message(model, d, id)));
      };
      return d.delay ? setTimeout(answer, d.delay) : answer();
    }
    log({ id, method: req.method, url: req.url, answer: "404" });
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ type: "error", error: { type: "not_found_error", message: "the proof stub has no " + path } }));
  });
});

server.listen(port, "127.0.0.1", () => log({ listening: port }));
