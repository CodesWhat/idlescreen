(() => {
  const canvas = document.querySelector("canvas");
  const context = canvas.getContext("webgl2", { preserveDrawingBuffer: true });
  if (!context) throw new Error("WebGL2 is unavailable");
  function shader(type, source) {
    const result = context.createShader(type);
    context.shaderSource(result, source);
    context.compileShader(result);
    if (!context.getShaderParameter(result, context.COMPILE_STATUS)) {
      throw new Error(context.getShaderInfoLog(result));
    }
    return result;
  }
  const program = context.createProgram();
  context.attachShader(program, shader(context.VERTEX_SHADER, `#version 300 es
    in vec2 position;
    uniform float offset;
    void main() { gl_Position = vec4(position + vec2(offset, 0.0), 0.0, 1.0); }
  `));
  context.attachShader(program, shader(context.FRAGMENT_SHADER, `#version 300 es
    precision mediump float;
    out vec4 color;
    void main() { color = vec4(0.41, 0.84, 0.79, 1.0); }
  `));
  context.linkProgram(program);
  if (!context.getProgramParameter(program, context.LINK_STATUS)) {
    throw new Error(context.getProgramInfoLog(program));
  }
  context.useProgram(program);
  const vertices = context.createBuffer();
  context.bindBuffer(context.ARRAY_BUFFER, vertices);
  context.bufferData(context.ARRAY_BUFFER, new Float32Array([
    0.2, 0, -0.1, 0.16, -0.1, -0.16,
    -0.08, 0, -0.24, 0.18, -0.24, -0.18
  ]), context.STATIC_DRAW);
  const position = context.getAttribLocation(program, "position");
  const offset = context.getUniformLocation(program, "offset");
  context.enableVertexAttribArray(position);
  context.vertexAttribPointer(position, 2, context.FLOAT, false, 0, 0);
  let running = false;
  let frame = null;
  let starts = 0;
  let stops = 0;
  let draws = 0;

  function draw(time) {
    context.clearColor(6 / 255, 27 / 255, 41 / 255, 1);
    context.clear(context.COLOR_BUFFER_BIT);
    context.uniform1f(offset, Math.sin(time / 1000) * 0.4);
    context.drawArrays(context.TRIANGLES, 0, 6);
    draws += 1;
  }

  function tick(time) {
    frame = null;
    if (!running) return;
    draw(time);
    frame = requestAnimationFrame(tick);
  }

  window.idleScreenScene = Object.freeze({
    setAnimating(active) {
      if (active === running) return;
      running = active;
      if (active) {
        starts += 1;
        draw(performance.now());
        frame = requestAnimationFrame(tick);
      } else {
        stops += 1;
        if (frame !== null) cancelAnimationFrame(frame);
        frame = null;
      }
    },
    status() {
      const backgroundPixel = new Uint8Array(4);
      context.readPixels(0, 0, 1, 1, context.RGBA, context.UNSIGNED_BYTE, backgroundPixel);
      return {
        resourceLoaded: true, graphicsAPI: "webgl2", backgroundPixel: Array.from(backgroundPixel),
        running, pendingFrames: frame === null ? 0 : 1, starts, stops, draws
      };
    }
  });
  draw(0);
})();
