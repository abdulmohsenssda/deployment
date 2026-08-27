// Shared command-run request and SSE helpers.
(() => {
  'use strict';

  const NETWORK_ERROR = 'Network error: could not reach the command endpoint. Check your connection and try again.';
  const STREAM_ERROR = 'Command failed: the output stream could not be read.';
  const MALFORMED_ERROR = 'Command failed: the output stream was malformed.';
  const CLOSED_ERROR = 'Command failed: the output stream closed before completion.';

  class CommandRunError extends Error {
    constructor(kind, message) {
      super(message);
      this.name = 'CommandRunError';
      this.kind = kind;
    }
  }

  function normalizeLineEndings(value) {
    return value.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  }

  async function responseText(response) {
    try {
      return (await response.text()).trim();
    } catch (_) {
      return '';
    }
  }

  async function execute(url, options, handlers = {}) {
    let response;
    try {
      response = await fetch(url, options);
    } catch (_) {
      throw new CommandRunError('network', NETWORK_ERROR);
    }

    if (!response || !response.ok) {
      const status = response?.status || 0;
      const detail = response ? await responseText(response) : '';
      const suffix = detail ? ': ' + detail.slice(0, 2000) : '';
      throw new CommandRunError('http', 'Command failed (HTTP ' + status + ')' + suffix);
    }

    if (!response.body || typeof response.body.getReader !== 'function') {
      throw new CommandRunError('stream', CLOSED_ERROR);
    }
    return readSSE(response.body, handlers);
  }

  async function readSSE(body, handlers = {}) {
    if (!body || typeof body.getReader !== 'function') {
      throw new CommandRunError('stream', CLOSED_ERROR);
    }

    let reader;
    try {
      reader = body.getReader();
    } catch (_) {
      throw new CommandRunError('stream', STREAM_ERROR);
    }

    const decoder = new TextDecoder();
    let buffer = '';
    let sawDone = false;
    let sawError = false;
    let errorData = '';

    const dispatch = block => {
      const lines = block.split('\n');
      let eventType = 'message';
      const dataLines = [];
      let fieldCount = 0;

      for (const line of lines) {
        if (!line || line.startsWith(':')) continue;
        const separator = line.indexOf(':');
        if (separator < 0) {
          throw new CommandRunError('malformed', MALFORMED_ERROR);
        }

        const field = line.slice(0, separator);
        if (!field) {
          throw new CommandRunError('malformed', MALFORMED_ERROR);
        }
        let value = line.slice(separator + 1);
        if (value.startsWith(' ')) value = value.slice(1);
        fieldCount++;

        if (field === 'event') eventType = value || 'message';
        else if (field === 'data') dataLines.push(value);
        // id, retry, and extension fields are valid SSE fields but do not
        // affect command output.
      }

      if (!fieldCount) return;
      const data = dataLines.join('\n');
      if (eventType === 'error') {
        sawError = true;
        errorData = data;
      } else if (eventType === 'done') {
        sawDone = true;
      }

      if (dataLines.length || eventType !== 'message') {
        handlers.onEvent?.({ type: eventType, data });
      }
    };

    try {
      while (true) {
        let chunk;
        try {
          chunk = await reader.read();
        } catch (_) {
          throw new CommandRunError('stream', STREAM_ERROR);
        }
        if (!chunk || typeof chunk !== 'object') {
          throw new CommandRunError('stream', STREAM_ERROR);
        }
        if (chunk.value != null) {
          buffer += normalizeLineEndings(decoder.decode(chunk.value, { stream: !chunk.done }));
        }
        if (chunk.done) break;

        let separator;
        while ((separator = buffer.indexOf('\n\n')) >= 0) {
          const block = buffer.slice(0, separator);
          buffer = buffer.slice(separator + 2);
          dispatch(block);
        }
      }

      buffer += normalizeLineEndings(decoder.decode());
      if (buffer.trim()) {
        throw new CommandRunError('malformed', MALFORMED_ERROR);
      }
    } catch (err) {
      if (err instanceof CommandRunError) throw err;
      throw new CommandRunError('stream', STREAM_ERROR);
    } finally {
      try {
        reader.releaseLock?.();
      } catch (_) {}
    }

    if (!sawDone) {
      throw new CommandRunError('closed', CLOSED_ERROR);
    }
    return { failed: sawError, error: errorData };
  }

  window.commandRun = Object.freeze({
    execute,
    readSSE,
    CommandRunError,
  });
})();
