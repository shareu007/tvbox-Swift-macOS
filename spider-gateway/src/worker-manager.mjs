import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { attachBoundedLineReader } from "./bounded-lines.mjs";
import { GatewayError } from "./errors.mjs";

class WorkerSession {
  constructor(options) {
    this.options = options;
    this.pending = new Map();
    this.lastUsedAt = Date.now();
    this.closed = false;
    this.process = spawn(options.command, options.args, {
      stdio: ["pipe", "pipe", "ignore"],
      env: { PATH: process.env.PATH || "", LANG: "C.UTF-8", SPIDER_SESSION_ID: options.sessionID }
    });
    this.lines = attachBoundedLineReader(this.process.stdout, {
      maximumBytes: options.maxLineBytes,
      onLine: (line) => this.#receive(line),
      onOverflow: () => {
        this.#failAll(new GatewayError("WORKER_RESPONSE_TOO_LARGE", "Spider worker response is too large", 502));
        this.close();
      },
      onError: (error) => {
        this.#failAll(new GatewayError("WORKER_EXITED", "Spider worker control channel failed", 502, { cause: error }));
        this.close();
      }
    });
    this.process.once("error", (error) => {
      this.closed = true;
      this.#failAll(new GatewayError("WORKER_START_FAILED", "Unable to start the Spider worker", 503, { cause: error }));
    });
    this.process.once("exit", () => {
      this.closed = true;
      this.lines.close();
      this.#failAll(new GatewayError("WORKER_EXITED", "The Spider worker exited unexpectedly", 502));
    });
  }

  async initialize(artifact, site) {
    await this.request({
      type: "init",
      session: this.options.sessionID,
      jarPath: artifact.path,
      jarDigest: artifact.digest,
      site
    });
  }

  request(payload) {
    if (this.closed) return Promise.reject(new GatewayError("WORKER_EXITED", "The Spider worker is unavailable", 502));
    this.lastUsedAt = Date.now();
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new GatewayError("SPIDER_TIMEOUT", "Spider execution timed out", 504));
        this.close();
      }, this.options.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.process.stdin.write(`${JSON.stringify({ id, ...payload })}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new GatewayError("WORKER_WRITE_FAILED", "Unable to communicate with the Spider worker", 502, { cause: error }));
      });
    });
  }

  #receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.#failAll(new GatewayError("INVALID_WORKER_RESPONSE", "Spider worker returned invalid JSON", 502));
      this.close();
      return;
    }
    const pending = this.pending.get(message.id);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(message.id);
    if (message.ok === true) pending.resolve(message.result ?? null);
    else pending.reject(new GatewayError(message.code || "SPIDER_ERROR", message.message || "Spider execution failed", 502));
  }

  #failAll(error) {
    if (this.closed && this.pending.size === 0) return;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.#failAll(new GatewayError("WORKER_STOPPED", "Spider worker stopped", 502));
    this.lines.close();
    const child = this.process;
    child.stdin.end();
    child.kill("SIGTERM");
    const forceKill = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 1_000);
    forceKill.unref();
  }
}

export class WorkerManager {
  constructor(options) {
    this.command = options.workerCommand;
    this.args = options.workerArgs;
    this.timeoutMs = options.workerTimeoutMs;
    this.idleMs = options.workerIdleMs;
    this.maxSessions = options.workerMaxSessions;
    this.maxLineBytes = options.workerMaxLineBytes;
    this.sessions = new Map();
    this.creating = new Map();
    this.startingSessions = new Set();
    this.closed = false;
    this.sweeper = setInterval(() => this.sweep(), Math.min(this.idleMs, 60_000));
    this.sweeper.unref();
  }

  async invoke(artifact, site, action, argumentsValue) {
    if (!this.command) {
      throw new GatewayError("WORKER_UNAVAILABLE", "No Android Spider worker is configured", 503);
    }
    const key = createHash("sha256")
      .update(artifact.digest).update("\0")
      .update(site.key).update("\0")
      .update(site.api).update("\0")
      .update(site.ext).digest("hex");
    const session = await this.#session(key, artifact, site);
    const result = await session.request({ type: "invoke", action, arguments: argumentsValue });
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      throw new GatewayError("INVALID_WORKER_RESPONSE", "Spider worker result must be a JSON object", 502);
    }
    return result;
  }

  async #session(key, artifact, site) {
    if (this.closed) {
      throw new GatewayError("WORKER_STOPPED", "Spider worker manager is stopped", 503);
    }
    const available = this.sessions.get(key);
    if (available && !available.closed) return available;
    const inflight = this.creating.get(key);
    if (inflight) return inflight;

    const creation = (async () => {
      if (this.sessions.size >= this.maxSessions) this.#evictOldest();
      const session = new WorkerSession({
        command: this.command,
        args: this.args,
        sessionID: key,
        timeoutMs: this.timeoutMs,
        maxLineBytes: this.maxLineBytes
      });
      this.startingSessions.add(session);
      try {
        await session.initialize(artifact, site);
        if (this.closed) {
          throw new GatewayError("WORKER_STOPPED", "Spider worker manager is stopped", 503);
        }
        this.sessions.set(key, session);
        return session;
      } catch (error) {
        session.close();
        throw error;
      } finally {
        this.startingSessions.delete(session);
      }
    })().finally(() => this.creating.delete(key));
    this.creating.set(key, creation);
    return creation;
  }

  #evictOldest() {
    const oldest = [...this.sessions.entries()].sort((a, b) => a[1].lastUsedAt - b[1].lastUsedAt)[0];
    if (!oldest) return;
    oldest[1].close();
    this.sessions.delete(oldest[0]);
  }

  sweep(now = Date.now()) {
    for (const [key, session] of this.sessions) {
      if (session.closed || now - session.lastUsedAt >= this.idleMs) {
        session.close();
        this.sessions.delete(key);
      }
    }
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.sweeper);
    for (const session of this.startingSessions) session.close();
    this.startingSessions.clear();
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }
}
